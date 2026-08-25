import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'local_db.dart';
import 'models.dart';

/// Everything that keeps [LocalDb] and Supabase in sync lives here.
/// [DataRepo] only ever reads/writes [LocalDb] for lists/items/products --
/// this is the only place that talks to Supabase for that data, via:
/// - a one-shot paginated download of the whole `products` table at start
///   (plus a periodic safety-net re-download, see [_productsRefreshTimer]),
/// - a raw realtime channel on `products` for single-row push updates --
///   this is what makes a price Digisoft itself changes (not through this
///   app) show up here within moments instead of only after the next full
///   refresh; a plain `.stream()` isn't used here like it is below, since
///   that resyncs the *entire* table on every single change, which is fine
///   for the small lists/items tables but wasteful for a product catalog
///   that can be thousands of rows,
/// - long-lived `.stream()` subscriptions on `lists`/`list_items` (each
///   emission is a fresh full-table snapshot, which doubles as both the
///   initial pull and every subsequent live update),
/// - a `pending_ops` queue, flushed in order, for local writes made while
///   offline (or that raced a flaky connection).
class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  SupabaseClient get _client => Supabase.instance.client;
  final _localDb = LocalDb.instance;

  StreamSubscription? _connSub;
  StreamSubscription? _listsSub;
  StreamSubscription? _itemsSub;
  StreamSubscription? _pendingChangesSub;
  RealtimeChannel? _productsChannel;
  Timer? _productsRefreshTimer;
  Timer? _pendingOpsRetryTimer;
  bool _started = false;
  bool _flushing = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    unawaited(pullProducts());
    unawaited(flushPendingOps());

    // Every .listen() below needs an onError -- Supabase's realtime client
    // throws a RealtimeSubscribeException whenever a (re)subscribe attempt
    // times out (a normal, transient thing on a flaky connection; it keeps
    // retrying on its own), and without an onError handler that becomes an
    // *unhandled* async exception that escapes to the root Zone. Harmless
    // to Flutter's own widget tree, but it's a genuine bug in its own right
    // (it just gets logged and silently dropped otherwise) and worth
    // closing off cleanly rather than leaving it unhandled.
    _listsSub = _client.from('lists').stream(primaryKey: ['id']).listen(
      (rows) {
        final lists = rows.map((r) => ProductList.fromJson(r)).toList();
        unawaited(_localDb.mergeRemoteLists(lists));
      },
      onError: (_) {},
    );

    _itemsSub = _client.from('list_items').stream(primaryKey: ['id']).listen(
      (rows) {
        final items = rows.map((r) => ListItem.fromJson(r)).toList();
        unawaited(_localDb.mergeRemoteItems(items));
      },
      onError: (_) {},
    );

    _pendingChangesSub = _client.from('product_pending_changes').stream(primaryKey: ['id']).listen(
      (rows) {
        final changes = rows.map((r) => PendingChange.fromJson(r)).toList();
        unawaited(_localDb.mergeRemotePendingChanges(changes));
      },
      onError: (_) {},
    );

    _productsChannel = _client
        .channel('public:products')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'products',
          callback: (payload) {
            if (payload.eventType == PostgresChangeEvent.delete) {
              final barcode = payload.oldRecord['barcode'] as String?;
              if (barcode != null) unawaited(_localDb.deleteProductLocal(barcode));
            } else {
              unawaited(_localDb.upsertSingleProduct(Product.fromJson(payload.newRecord)));
            }
          },
        )
        .subscribe();

    // Self-healing net in case a realtime event is ever missed (dropped
    // connection mid-change, etc.) -- infrequent since the channel above
    // handles the normal case, so a full re-download here is cheap enough.
    _productsRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) => unawaited(pullProducts()));

    // flushPendingOps is otherwise only triggered by an explicit local write
    // or a connectivity-regained event -- if a single flush attempt fails
    // for any other reason (a transient timeout, the connectivity plugin
    // missing a transition), the queued op just sits there with nothing to
    // ever retry it, silently blocking every op queued after it (order is
    // preserved by stopping at the first failure). This is what let one
    // user's "unstage after send" queue up but never actually reach
    // Supabase, leaving every other device showing it as still pending long
    // after the price had already changed at the till. A periodic retry
    // makes that self-heal within a couple minutes instead of requiring an
    // app restart.
    _pendingOpsRetryTimer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(flushPendingOps()));

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(pullProducts());
        unawaited(flushPendingOps());
      }
    });
  }

  Future<void> stop() async {
    _started = false;
    await _connSub?.cancel();
    await _listsSub?.cancel();
    await _itemsSub?.cancel();
    await _pendingChangesSub?.cancel();
    if (_productsChannel != null) await _client.removeChannel(_productsChannel!);
    _productsRefreshTimer?.cancel();
    _pendingOpsRetryTimer?.cancel();
    _connSub = null;
    _listsSub = null;
    _itemsSub = null;
    _pendingChangesSub = null;
    _productsChannel = null;
    _productsRefreshTimer = null;
    _pendingOpsRetryTimer = null;
  }

  static const _lastProductSyncKey = 'last_product_sync_at';
  static const _lastProductFullSyncKey = 'last_product_full_sync_at';
  // One-time forced full resync so already-synced devices actually pick up
  // the `kdv_rate` column (added 2026-08-23, backfilled by the till-PC
  // bridge directly via SQL) -- a plain incremental pull only re-fetches
  // rows whose `updated_at` changed, and a bulk backfill UPDATE run outside
  // this app's own write paths has no reason to have touched that column,
  // so most rows would otherwise silently sit with a stale/null kdv_rate
  // in the local cache until the next 6-hourly full resync happens to land.
  static const _kdvBackfillSyncKey = 'kdv_rate_backfill_synced_2026_08_23';
  // Realtime (the channel below) is the primary way product changes reach
  // this device -- this periodic pull is only ever a self-healing net for a
  // missed event. A full reconciliation (delete-and-replace, so it also
  // catches a deletion missed while offline) is only worth its cost
  // occasionally; an incremental "what changed since last time" pull
  // covers everything else far more cheaply and can run every cycle.
  static const _fullSyncInterval = Duration(hours: 6);

  /// [full] forces a complete re-download + replace regardless of when the
  /// last one ran -- otherwise this pulls incrementally (only rows changed
  /// since the last successful pull) once an initial full pull has ever
  /// completed, falling back to a full pull on a genuinely first-ever run
  /// or once [_fullSyncInterval] has passed.
  Future<void> pullProducts({bool full = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSyncRaw = prefs.getString(_lastProductSyncKey);
      final lastFullSyncRaw = prefs.getString(_lastProductFullSyncKey);
      final lastFullSync = lastFullSyncRaw == null ? null : DateTime.tryParse(lastFullSyncRaw);
      final needsFull = full ||
          lastSyncRaw == null ||
          lastFullSync == null ||
          DateTime.now().toUtc().difference(lastFullSync) > _fullSyncInterval ||
          // The watermark alone can't be trusted -- SharedPreferences and
          // the SQLite file don't share a lifecycle, so a watermark saying
          // "already synced" can survive the product table underneath it
          // being emptied out from under it.
          !await LocalDb.instance.hasAnyProducts() ||
          !(prefs.getBool(_kdvBackfillSyncKey) ?? false);
      final since = needsFull ? null : DateTime.tryParse(lastSyncRaw);

      final products = <Product>[];
      const pageSize = 1000;
      var start = 0;
      while (true) {
        var query = _client.from('products').select('barcode, pluno, stockname, price, depno, stockunit, search_key, kdv_rate');
        if (since != null) query = query.gt('updated_at', since.toIso8601String());
        final rows = await query.range(start, start + pageSize - 1).timeout(const Duration(seconds: 20));
        final page = rows.map((r) => Product.fromJson(r)).toList();
        products.addAll(page);
        if (page.length < pageSize) break;
        start += pageSize;
      }

      if (needsFull) {
        await LocalDb.instance.replaceAllProducts(products);
        await prefs.setString(_lastProductFullSyncKey, DateTime.now().toUtc().toIso8601String());
        await prefs.setBool(_kdvBackfillSyncKey, true);
      } else {
        for (final product in products) {
          await LocalDb.instance.upsertSingleProduct(product);
        }
      }
      // A couple of minutes' overlap rather than the exact fetch time, so
      // clock skew between this device and the server can't cause a
      // product updated right around now to be silently skipped next
      // cycle -- cheap insurance given this only ever re-fetches a handful
      // of recently-touched rows either way.
      final watermark = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
      await prefs.setString(_lastProductSyncKey, watermark.toIso8601String());
    } catch (e, st) {
      // Offline, or first run before any connection ever succeeded --
      // whatever's already cached from a previous run stands as-is. Logged
      // (not surfaced to staff) purely so this isn't a silent black box
      // when diagnosing a stale/incomplete local catalog.
      debugPrint('pullProducts failed (non-fatal): $e\n$st');
    }
  }

  /// Called after every local write so an online user's own change reaches
  /// the server right away instead of waiting for the next trigger; falls
  /// back to the queue silently (via [flushPendingOps]'s own error handling)
  /// when there's no connection.
  Future<void> pushNow() => flushPendingOps();

  /// What the *oldest* queued op is currently blocked on, if anything --
  /// null once it clears. This is what actually blocks every op behind it
  /// (order is preserved by stopping at the first failure), so it's the one
  /// piece of information that explains a stuck backlog. Previously this
  /// was silently swallowed, which is exactly why a stuck queue could sit
  /// there with no way for anyone -- staff or a remote debugging session --
  /// to tell why. See widgets/pending_ops_debug_screen.dart.
  final ValueNotifier<({String kind, String error})?> lastFlushError = ValueNotifier(null);

  Future<void> flushPendingOps() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (true) {
        final ops = await _localDb.allPendingOps();
        if (ops.isEmpty) {
          lastFlushError.value = null;
          break;
        }
        final op = ops.first;
        final kind = op['kind'] as String;
        final payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
        try {
          await _applyOp(kind, payload).timeout(const Duration(seconds: 10));
          await _localDb.deletePendingOp(op['id'] as int);
          lastFlushError.value = null;
        } catch (e) {
          // Network (or other) failure -- stop here to preserve op order,
          // the next trigger (connectivity regained / next local write) retries.
          lastFlushError.value = (kind: kind, error: e.toString());
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _applyOp(String kind, Map<String, dynamic> payload) async {
    switch (kind) {
      case 'create_list':
        // created_at is only present when this came from restoreList
        // (undoing a delete) -- a plain createList lets Postgres default it.
        await _client.from('lists').insert({
          'id': payload['id'],
          'name': payload['name'],
          'type': payload['type'],
          'fields': payload['fields'],
          if (payload['created_at'] != null) 'created_at': payload['created_at'],
        });
      case 'delete_list':
        await _client.from('lists').delete().eq('id', payload['id']);
      case 'add_item':
        // quantity/new_price/custom_data/scanned_at are only ever present
        // when this op came from restoreListItem (undoing a delete) -- a
        // plain addListItem never sets them, so this stays backward
        // compatible with older queued ops too.
        await _client.from('list_items').insert({
          'id': payload['id'],
          'list_id': payload['list_id'],
          'barcode': payload['barcode'],
          if (payload['note'] != null) 'note': payload['note'],
          if (payload['quantity'] != null) 'quantity': payload['quantity'],
          if (payload['new_price'] != null) 'new_price': payload['new_price'],
          if (payload['custom_data'] != null) 'custom_data': payload['custom_data'],
          if (payload['scanned_at'] != null) 'scanned_at': payload['scanned_at'],
        });
      case 'update_item':
        await _client.from('list_items').update({payload['field'] as String: payload['value']}).eq(
            'id', payload['id']);
      case 'delete_item':
        await _client.from('list_items').delete().eq('id', payload['id']);
      case 'stage_change':
        await _client.from('product_pending_changes').upsert({
          'id': payload['id'],
          'barcode': payload['barcode'],
          'field': payload['field'],
          'new_value': payload['new_value'],
          'source_list_id': payload['source_list_id'],
          'source_list_name': payload['source_list_name'],
          'requested_by': payload['requested_by'],
        });
      case 'unstage_change':
        await _client.from('product_pending_changes').delete().eq('id', payload['id']);
      case 'log_action':
        await _client.from('activity_log').insert({
          'user_name': payload['user_name'],
          'action': payload['action'],
          'detail': payload['detail'],
        });
    }
  }
}
