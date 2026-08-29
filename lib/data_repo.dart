import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'config.dart';
import 'local_db.dart';
import 'models.dart';
import 'normalize.dart';
import 'platform_util.dart';
import 'sync_engine.dart';

const _uuid = Uuid();
const _staffNameKey = 'staff_name';

class DataRepo {
  SupabaseClient get _client => Supabase.instance.client;
  final _localDb = LocalDb.instance;

  bool get isSignedIn => _client.auth.currentSession != null;

  /// Staff enter just the shared password; the fixed shared-account email
  /// is an implementation detail they never see.
  Future<void> signIn(String password) async {
    await _client.auth.signInWithPassword(
      email: sharedStaffEmail,
      password: password,
    );
  }

  Future<void> signOut() async {
    await SyncEngine.instance.stop();
    await _client.auth.signOut();
  }

  // ---- staff name (used for chat + activity log) ----

  Future<String?> getStaffName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_staffNameKey);
    return (name == null || name.trim().isEmpty) ? null : name.trim();
  }

  Future<void> setStaffName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_staffNameKey, name.trim());
  }

  // ---- activity log (best-effort, queued like any other write so it still
  // lands once back online) ----

  Future<void> logAction(String action, {String? detail}) async {
    final name = await getStaffName() ?? 'Bilinmiyor';
    await _localDb.enqueueOp('log_action', {'user_name': name, 'action': action, 'detail': detail});
    unawaited(SyncEngine.instance.pushNow());
  }

  /// Read-only history of every logged staff action, newest first -- feeds
  /// the desktop "Ayarlar" tab's İşlem Geçmişi list. Online-only (no local
  /// cache): it's a review screen, not something needed offline.
  Future<List<ActivityEntry>> getActivityLog({int limit = 300}) async {
    try {
      final rows = await _client
          .from('activity_log')
          .select('created_at, user_name, action, detail')
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 8));
      return rows.map((r) => ActivityEntry.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }

  // ---- in-app messaging (online-only -- a chat message with no recipient
  // yet online has nothing useful to reach, so this isn't queued offline) ----

  Stream<List<ChatMessage>> watchMessages() {
    return _client
        .from('chat_messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .map((rows) => rows.map((r) => ChatMessage.fromJson(r)).toList());
  }

  /// Caller supplies [id] (client-generated) so the UI can show the message
  /// optimistically the instant it's sent and reconcile it against the same
  /// row once the realtime stream confirms it -- instead of waiting for the
  /// round trip before anything appears.
  Future<void> sendMessage(String id, String senderName, String body) =>
      _client.from('chat_messages').insert({'id': id, 'sender_name': senderName, 'body': body.trim()});

  // ---- products (try live server first for freshest data/prices, fall back
  // to the on-device catalog when offline) ----

  Future<Product?> lookupBarcode(String barcode) async {
    final trimmed = barcode.trim();
    try {
      final row = await _client
          .from('products')
          .select('barcode, pluno, stockname, price, depno, stockunit, search_key, kdv_rate')
          .eq('barcode', trimmed)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (row == null) return null;
      final product = Product.fromJson(row);
      // A live fetch found this, but that doesn't mean the local cache has
      // it yet (initial/periodic sync may just not have reached it) --
      // anything staged straight off this result (product_pending_changes'
      // "old value" side, the "already applied" double-check) reads from
      // the local cache, not from what's on screen, so without this a
      // freshly-searched/scanned product could show as having no known
      // current name/price at all.
      unawaited(_localDb.upsertSingleProduct(product));
      return product;
    } catch (_) {
      return _localDb.lookupProductLocal(trimmed);
    }
  }

  /// Bulk barcode -> product lookup against the local cache only, used by
  /// the Excel bulk-import review screen. Deliberately local-only (not a
  /// live Supabase query) -- the local products cache is kept fully synced
  /// on desktop (see SyncEngine.pullProducts), so this is both instant and
  /// avoids sending a potentially very large barcode list over the network.
  Future<Map<String, Product>> lookupProductsLocal(List<String> barcodes) => _localDb.lookupProductsLocal(barcodes);

  Future<List<Product>> searchProducts(String query) async {
    final normalized = normalizeTurkish(query).replaceAll(RegExp(r'[,()%_]'), ' ').trim();
    final digits = query.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalized.isEmpty && digits.isEmpty) return [];

    // Desktop: search the local catalog first instead of Supabase --
    // SyncEngine keeps it synced (full pull at startup, realtime channel,
    // incremental periodic refresh), so this is normally instant with no
    // network round trip. But that local copy can genuinely be
    // empty/incomplete (a fresh install before the first full pull
    // finishes, a sync hiccup, this device just never having searched that
    // product before) -- searching *only* ever local, with nothing to fall
    // back on, turned "not synced yet" into a false "ürün bulunamadı" that
    // looked like the product didn't exist at all. Falling back to a live
    // check whenever local comes back empty keeps the fast path fast
    // without ever trusting an incomplete cache as if it were authoritative.
    if (isDesktopPlatform) {
      final local = await _localDb.searchProductsLocal(normalized, digits);
      if (local.isNotEmpty) return local;
      try {
        return await _searchProductsLive(normalized, digits);
      } catch (_) {
        return local; // offline and nothing cached -- genuinely nothing to show
      }
    }

    // Mobile searches live first (a phone's local cache is more likely to
    // be stale/incomplete -- it was never the primary path there), falling
    // back to whatever's cached only if the live call itself fails
    // (offline).
    try {
      return await _searchProductsLive(normalized, digits);
    } catch (_) {
      return _localDb.searchProductsLocal(normalized, digits);
    }
  }

  Future<List<Product>> _searchProductsLive(String normalized, String digits) async {
    final filters = <String>[];
    if (normalized.isNotEmpty) filters.add('search_key.ilike.%$normalized%');
    if (digits.isNotEmpty) filters.add('barcode.ilike.%$digits%');

    final rows = await _client
        .from('products')
        .select('barcode, pluno, stockname, price, depno, stockunit, search_key, kdv_rate')
        .or(filters.join(','))
        .order('stockname')
        .limit(200)
        .timeout(const Duration(seconds: 5));
    final products = rows.map((r) => Product.fromJson(r)).toList();
    // Warm the local cache with whatever a live search just found, so the
    // fast local path above finds it next time.
    for (final p in products) {
      unawaited(_localDb.upsertSingleProduct(p));
    }
    return products;
  }

  // ---- product edits (price/name/unit/department). These insert a request
  // row that a separate Windows service on the store's till PC polls and
  // applies to Digisoft + the physical kasa -- see
  // barkod-tarayici/TILL_PC_GOREVLERI.md and SEMATIK.md for that
  // side. The app only ever inserts + watches; it never sets `status`
  // itself (RLS blocks that, only that service's key can).

  Future<int> requestPriceUpdate(String barcode, num newPrice, {num? oldPrice}) async {
    final name = await getStaffName();
    final row = await _client
        .from('price_update_requests')
        .insert({'barcode': barcode, 'new_price': newPrice, 'old_price': oldPrice, 'requested_by': name})
        .select('id')
        .single();
    unawaited(logAction('fiyat_guncelleme_istegi', detail: '$barcode -> $newPrice'));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchPriceUpdateStatus(int id) {
    return _client
        .from('price_update_requests')
        .stream(primaryKey: ['id'])
        .eq('id', id)
        .map(_toRequestStatus);
  }

  Future<int> requestFieldUpdate(String barcode, String field, String newValue, {String? oldValue}) async {
    final name = await getStaffName();
    final row = await _client
        .from('product_field_update_requests')
        .insert({'barcode': barcode, 'field': field, 'new_value': newValue, 'old_value': oldValue, 'requested_by': name})
        .select('id')
        .single();
    unawaited(logAction('urun_alani_guncelleme_istegi', detail: '$barcode.$field -> $newValue'));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchFieldUpdateStatus(int id) {
    return _client
        .from('product_field_update_requests')
        .stream(primaryKey: ['id'])
        .eq('id', id)
        .map(_toRequestStatus);
  }

  ({String status, String? errorMessage}) _toRequestStatus(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return (status: 'pending', errorMessage: null);
    final row = rows.first;
    return (status: row['status'] as String, errorMessage: row['error_message'] as String?);
  }

  /// Same request-queue pattern once more, for the Argox label printer
  /// physically attached to the till PC -- see
  /// barkod-tarayici/TILL_PC_GOREVLERI.md for that side.
  Future<int> requestLabelPrint(String barcode, int quantity) async {
    final name = await getStaffName();
    final row = await _client
        .from('label_print_requests')
        .insert({'barcode': barcode, 'quantity': quantity, 'requested_by': name})
        .select('id')
        .single();
    unawaited(logAction('etiket_yazdirma_istegi', detail: '$barcode x$quantity'));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchLabelPrintStatus(int id) =>
      _pollRequestStatus('label_print_requests', id);

  /// Polls instead of using Supabase's realtime `.stream()` (unlike the
  /// list/pending-change watchers above) -- a one-shot check for a single
  /// user, not a live multi-client sync, so there's no benefit to realtime
  /// here, and polling sidesteps it entirely as a failure mode: if a table
  /// were ever missing from the realtime publication (or the socket just
  /// drops), a `.stream()`-based watcher silently never emits again and the
  /// UI is stuck showing "Bekliyor…" forever with no way to tell why.
  /// Polling always eventually reads the real row. Screens using this also
  /// layer their own short timeout on top so staff aren't left staring at a
  /// spinner even if the till-PC service itself is the thing that's down.
  Stream<({String status, String? errorMessage})> _pollRequestStatus(String table, int id) async* {
    for (var i = 0; i < 30; i++) {
      try {
        final rows = await _client.from(table).select('status, error_message').eq('id', id).limit(1);
        final result = _toRequestStatus(rows);
        yield result;
        if (result.status == 'done' || result.status == 'error') return;
      } catch (_) {
        // Transient network hiccup -- keep polling.
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  // ---- KDV departments (fixed lookup list the till-PC maintains) ----

  Future<List<KdvDepartment>> getKdvDepartments() async {
    final rows = await _client.from('kdv_departments').select('kasadepid, name, kdv_rate').order('kasadepid');
    return rows.map((r) => KdvDepartment.fromJson(r)).toList();
  }

  // ---- new product creation ----

  Future<int> requestProductCreate({
    required String barcode,
    required String stockname,
    required num price,
    int? kasadepid,
    num? kdvRate,
    String? stockunit,
    String? reyon,
  }) async {
    final name = await getStaffName();
    final row = await _client
        .from('product_create_requests')
        .insert({
          'barcode': barcode,
          'stockname': stockname,
          'price': price,
          'kasadepid': kasadepid,
          'kdv_rate': kdvRate,
          'stockunit': stockunit,
          'reyon': reyon,
          'requested_by': name,
        })
        .select('id')
        .single();
    unawaited(logAction('yeni_urun_istegi', detail: '$barcode - $stockname'));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchProductCreateStatus(int id) =>
      _pollRequestStatus('product_create_requests', id);

  // ---- "Teraziye Gönder" -- CAS-LP scale PLU export (CASLP16.PLU). Staff
  // pick one of their own lists (same `lists`/`list_items` this app already
  // uses for Listelerim), review/correct each item's name, price, barcode,
  // and PLU number, then send. The edited item data itself is the payload
  // -- encoded as JSON in `list` (still just a text column) -- rather than
  // a department name the till-PC service would have to resolve against
  // its own live Digisoft data, since the whole point here is sending
  // exactly what staff just corrected.

  Future<int> requestEslExport({required String listName, required List<Map<String, dynamic>> items}) async {
    final name = await getStaffName();
    final payload = jsonEncode({'listName': listName, 'items': items});
    final row = await _client
        .from('esl_export_requests')
        .insert({'list': payload, 'item_count': items.length, 'requested_by': name})
        .select('id')
        .single();
    unawaited(logAction('teraziye_gonderim_istegi', detail: '$listName (${items.length} ürün)'));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchEslExportStatus(int id) => _pollRequestStatus('esl_export_requests', id);

  // ---- product deletion ----

  Future<int> requestProductDelete(String barcode) async {
    final name = await getStaffName();
    final row = await _client
        .from('product_delete_requests')
        .insert({'barcode': barcode, 'requested_by': name})
        .select('id')
        .single();
    unawaited(logAction('urun_silme_istegi', detail: barcode));
    return row['id'] as int;
  }

  Stream<({String status, String? errorMessage})> watchProductDeleteStatus(int id) =>
      _pollRequestStatus('product_delete_requests', id);

  /// Whether the till-PC sync service is alive right now (per its
  /// heartbeat) -- lets the editor warn staff that a submitted update may
  /// sit in `pending` for a while instead of looking like it's stuck.
  Future<bool> isSyncHealthy() async {
    try {
      final res = await _client.functions.invoke('sync-status').timeout(const Duration(seconds: 5));
      return res.status == 200;
    } catch (_) {
      return false;
    }
  }

  // ---- lists (local-first: always read/write the on-device cache, which
  // SyncEngine keeps mirrored to/from Supabase) ----

  // These wrap the local query in try/catch because they feed `async*`
  // stream generators below (watchLists/watchListItems/
  // watchPendingChangesForBarcode/watchAllPendingChanges) -- an uncaught
  // exception inside one of those terminates the stream permanently, which
  // left the UI stuck on a loading spinner forever after a schema upgrade
  // raced a query once. A transient failure now degrades to "no data yet"
  // instead, and the next `_localDb.changes` ping (there's always another
  // along shortly) retries.
  // Excludes the two Teraziye-only lists (MANAV/SARKUTERI) -- those are
  // real rows in `lists` but are only ever meant to be worked with from
  // the Teraziye Gönder tab (see kasaya_gonder_screen.dart's own
  // getReservedTeraziyeLists), not browsed/picked from Listelerim, Ürün
  // Ara's "Listeye Ekle", or any other list picker.
  Future<List<ProductList>> getLists() async {
    try {
      final lists = await _localDb.getLists();
      return lists.where((l) => !reservedTeraziyeListNames.contains(l.name)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<ProductList>> getReservedTeraziyeLists() async {
    try {
      final lists = await _localDb.getLists();
      return lists.where((l) => reservedTeraziyeListNames.contains(l.name)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<ProductList?> getListById(String id) => _localDb.getListById(id);

  Stream<List<ProductList>> watchLists() async* {
    yield await getLists();
    await for (final _ in _localDb.changes) {
      yield await getLists();
    }
  }

  Future<ProductList> createList(String name, ListKind type, List<CustomField> fields) async {
    final list = ProductList(id: _uuid.v4(), name: name, type: type, fields: fields, createdAt: DateTime.now());
    await _localDb.upsertListLocal(list);
    await _localDb.enqueueOp('create_list', {
      'id': list.id,
      'name': name,
      'type': type.dbValue,
      'fields': fields.map((f) => f.toJson()).toList(),
    });
    unawaited(SyncEngine.instance.pushNow());
    unawaited(logAction('liste_olusturuldu', detail: name));
    return list;
  }

  /// Lets a list's info fields (what shows on each product card in it) be
  /// changed after creation -- creation no longer asks for a list "type",
  /// just these fields, so getting them wrong isn't a one-shot mistake any
  /// more.
  Future<void> updateListFields(String id, List<CustomField> fields) async {
    final list = await getListById(id);
    if (list == null) return;
    final updated = ProductList(id: list.id, name: list.name, type: list.type, fields: fields, createdAt: list.createdAt);
    await _localDb.upsertListLocal(updated);
    await _localDb.enqueueOp('update_list', {
      'id': id,
      'fields': fields.map((f) => f.toJson()).toList(),
    });
    unawaited(SyncEngine.instance.pushNow());
    unawaited(logAction('liste_alanlari_guncellendi', detail: list.name));
  }

  Future<void> deleteList(String id) async {
    await _localDb.hardDeleteListAndItems(id);
    await _localDb.enqueueOp('delete_list', {'id': id});
    unawaited(SyncEngine.instance.pushNow());
    unawaited(logAction('liste_silindi', detail: id));
  }

  /// Undoes a [deleteList] within its grace window -- same pattern as
  /// [restoreListItem]: re-inserts the list with its exact original id and
  /// createdAt (so it reappears in the same sort position), then restores
  /// every one of its items the same way.
  Future<void> restoreList(ProductList list, List<ListItem> items) async {
    await _localDb.upsertListLocal(list);
    await _localDb.enqueueOp('create_list', {
      'id': list.id,
      'name': list.name,
      'type': list.type.dbValue,
      'fields': list.fields.map((f) => f.toJson()).toList(),
      'created_at': list.createdAt.toIso8601String(),
    });
    unawaited(SyncEngine.instance.pushNow());
    for (final item in items) {
      await restoreListItem(item);
    }
    unawaited(logAction('liste_geri_eklendi', detail: list.name));
  }

  // ---- list items ----

  Future<List<ListItem>> getListItems(String listId) async {
    try {
      return await _localDb.getListItems(listId);
    } catch (_) {
      return [];
    }
  }

  Stream<List<ListItem>> watchListItems(String listId) async* {
    yield await getListItems(listId);
    await for (final _ in _localDb.changes) {
      yield await getListItems(listId);
    }
  }

  Future<ListItem> addListItem(String listId, String barcode, {String? note}) async {
    final trimmedNote = note?.trim();
    final item = ListItem(
      id: _uuid.v4(),
      listId: listId,
      barcode: barcode,
      note: (trimmedNote == null || trimmedNote.isEmpty) ? null : trimmedNote,
      customData: const {},
    );
    await _localDb.upsertItemLocal(item);
    await _localDb.enqueueOp('add_item', {
      'id': item.id,
      'list_id': listId,
      'barcode': barcode,
      'note': item.note,
    });
    unawaited(SyncEngine.instance.pushNow());
    unawaited(logAction('urun_listeye_eklendi', detail: barcode));
    return item;
  }

  /// Each screen only ever updates the one field its list type uses, so the
  /// caller passes exactly that field (nullable, to allow clearing it) and
  /// leaves the rest as sentinel-unset.
  Future<void> updateItemQuantity(String itemId, num? quantity) => _updateItemField(itemId, 'quantity', quantity);

  Future<void> updateItemNewPrice(String itemId, num? newPrice) => _updateItemField(itemId, 'new_price', newPrice);

  Future<void> updateItemNote(String itemId, String? note) => _updateItemField(itemId, 'note', note);

  Future<void> _updateItemField(String itemId, String field, dynamic value) async {
    await _localDb.updateItemFieldLocal(itemId, field, value);
    await _localDb.enqueueOp('update_item', {'id': itemId, 'field': field, 'value': value});
    unawaited(SyncEngine.instance.pushNow());
  }

  Future<void> deleteListItem(String itemId) async {
    await _localDb.hardDeleteItem(itemId);
    await _localDb.enqueueOp('delete_item', {'id': itemId});
    unawaited(SyncEngine.instance.pushNow());
  }

  /// Undoes a [deleteListItem] within its grace window -- re-inserts with
  /// the exact same id/barcode/quantity/newPrice/note/customData *and*
  /// original scannedAt, so the item reappears in the same sort position
  /// it was deleted from (list_items sorts by scanned_at desc) rather than
  /// jumping to the top as a "new" item would.
  Future<void> restoreListItem(ListItem item) async {
    await _localDb.upsertItemLocal(item);
    await _localDb.enqueueOp('add_item', {
      'id': item.id,
      'list_id': item.listId,
      'barcode': item.barcode,
      'note': item.note,
      'quantity': item.quantity,
      'new_price': item.newPrice,
      'custom_data': item.customData,
      'scanned_at': item.scannedAt.toIso8601String(),
    });
    unawaited(SyncEngine.instance.pushNow());
    unawaited(logAction('urun_listeye_geri_eklendi', detail: item.barcode));
  }

  // ---- staged product-change review ("Kasaya Gönder" tab). Staging is
  // local-first (SQLite + pending_ops, synced like lists/list_items) and
  // never reaches Digisoft/kasa/products until sendPendingChange is called
  // for that specific staged row. Not tied to any one list -- can be staged
  // from a list item's pencil icon (pass listId/listName) or directly from
  // "Ürün Ara" search results (leave them null).

  Future<List<PendingChange>> getPendingChangesForBarcode(String barcode) async {
    try {
      return await _localDb.getPendingChangesForBarcode(barcode);
    } catch (_) {
      return [];
    }
  }

  Stream<List<PendingChange>> watchPendingChangesForBarcode(String barcode) async* {
    yield await getPendingChangesForBarcode(barcode);
    await for (final _ in _localDb.changes) {
      yield await getPendingChangesForBarcode(barcode);
    }
  }

  Future<List<PendingChange>> getAllPendingChanges() async {
    try {
      return await _localDb.getAllPendingChanges();
    } catch (_) {
      return [];
    }
  }

  Stream<List<PendingChange>> watchAllPendingChanges() async* {
    yield await getAllPendingChanges();
    await for (final _ in _localDb.changes) {
      yield await getAllPendingChanges();
    }
  }

  Future<void> stageChange({
    required String barcode,
    required String field,
    required String value,
    String? listId,
    String? listName,
  }) async {
    final name = await getStaffName();
    final change = PendingChange(
      id: PendingChange.idFor(barcode, field),
      barcode: barcode,
      field: field,
      newValue: value,
      sourceListId: listId,
      sourceListName: listName,
      requestedBy: name,
    );
    await _localDb.upsertPendingChangeLocal(change);
    await _localDb.enqueueOp('stage_change', {
      'id': change.id,
      'barcode': barcode,
      'field': field,
      'new_value': value,
      'source_list_id': listId,
      'source_list_name': listName,
      'requested_by': name,
    });
    unawaited(SyncEngine.instance.pushNow());
  }

  /// Unlike every other write in this file, this tries a direct delete
  /// first instead of only queuing one -- `sendPendingChange` calls this
  /// right after a direct (non-queued) insert into the till-PC request
  /// table already succeeded, so we know we're online at that moment. That
  /// matters because until the queued delete actually reaches Supabase,
  /// every *other* device still sees this row (and its stale product data)
  /// via the live `product_pending_changes` stream -- the price itself can
  /// already be updated at the till while their screen still shows it as
  /// unsent. Falling back to the queue on failure keeps the offline case
  /// working exactly as before.
  Future<void> unstageChange(String id) async {
    await _localDb.deletePendingChangeLocal(id);
    // If the original 'stage_change' op never reached Supabase yet (staged
    // while offline, or just not flushed yet), there's nothing there for a
    // direct delete to find -- cancel that queued op outright instead, or
    // it would flush afterwards and resurrect the row this call just
    // cancelled locally.
    if (await _localDb.cancelQueuedOp('stage_change', id)) return;
    try {
      await _client.from('product_pending_changes').delete().eq('id', id).timeout(const Duration(seconds: 5));
    } catch (_) {
      await _localDb.enqueueOp('unstage_change', {'id': id});
      unawaited(SyncEngine.instance.pushNow());
    }
  }

  /// Local write-queue backlog on this device -- 0 once everything's
  /// reached Supabase. Surfaced in the UI (home_shell.dart) so staff can
  /// tell "still sitting on my phone" apart from "sent, waiting on the
  /// till-PC" instead of the two looking identical.
  Stream<int> watchPendingOpsCount() async* {
    yield await _localDb.pendingOpsCount();
    await for (final _ in _localDb.changes) {
      yield await _localDb.pendingOpsCount();
    }
  }

  /// Raw queued-op rows (kind/payload/created_at), oldest first -- feeds
  /// the pending-ops debug screen (reached by tapping the backlog banner)
  /// so a stuck queue can actually be inspected instead of just counted.
  Future<List<Map<String, Object?>>> getPendingOpsDebugInfo() => _localDb.allPendingOps();

  /// When the till-PC sync service last checked in -- shown alongside
  /// [isSyncHealthy]'s healthy/unhealthy dot so staff can tell "just went
  /// down a few seconds ago" apart from "been down for an hour", instead of
  /// a bare binary status. No RLS on this table -- it's operational
  /// metadata, not staff data.
  Future<DateTime?> getSyncHeartbeat() async {
    try {
      final row = await _client
          .from('sync_heartbeat')
          .select('last_seen_at')
          .eq('id', 1)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      final raw = row?['last_seen_at'] as String?;
      return raw == null ? null : DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Sends one staged change through the real Digisoft/kasa pipeline, then
  /// clears it from staging on success. If [alsoPrintLabel] is set, also
  /// queues a label print for that barcode ("Gönder ve Etiket Bastır") --
  /// the label reflects the change since the till-PC service prints from
  /// Digisoft's own (by-then-updated) data, not a stale snapshot. Returns an
  /// error message on failure (the staged row is left in place so it can be
  /// retried), or null on success.
  Future<String?> sendPendingChange(PendingChange change, {bool alsoPrintLabel = false}) async {
    try {
      final Stream<({String status, String? errorMessage})> statusStream;
      if (change.field == 'price') {
        final id = await requestPriceUpdate(change.barcode, num.parse(change.newValue), oldPrice: change.product?.price);
        statusStream = watchPriceUpdateStatus(id);
      } else {
        final oldValue = switch (change.field) {
          'stockname' => change.product?.stockname,
          'stockunit' => change.product?.stockunit,
          'depno' => change.product?.depno,
          _ => null,
        };
        final id = await requestFieldUpdate(change.barcode, change.field, change.newValue, oldValue: oldValue);
        statusStream = watchFieldUpdateStatus(id);
      }
      // The forward-sync (Digisoft -> Supabase) that follows a 'done' status
      // has its own few-second lag -- force a direct re-fetch of just this
      // product once it lands, so the local cache (and anything reading
      // from it: lists, search) catches up promptly and reliably instead of
      // only depending on the general products realtime channel.
      unawaited(_refreshAfterDone(change.barcode, statusStream));
      if (alsoPrintLabel) {
        unawaited(requestLabelPrint(change.barcode, 1));
      }
      await unstageChange(change.id);
      unawaited(logAction('kasaya_gonderildi', detail: '${change.barcode}.${change.field} -> ${change.newValue}'));
      return null;
    } catch (_) {
      return 'Gönderilemedi (bağlantı yok olabilir).';
    }
  }

  /// Digisoft -> Supabase forward-sync has its own lag after a request hits
  /// 'done', and how long that takes isn't fixed -- a single re-fetch a few
  /// seconds later can still land before the product row actually updates.
  /// Re-checks a handful of times over about a minute instead of trusting
  /// one shot, so the local cache (and the "already applied" double-check
  /// warning on Kasaya Gönder, which reads straight from it) reliably
  /// catches up rather than occasionally missing a slow sync.
  // Gaps between checks, not absolute offsets -- cumulative landing times
  // are 5s/15s/30s/50s after 'done', so all four checks land inside about
  // a minute rather than one running long past it.
  static const _refreshDelaysAfterDone = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 20),
  ];

  Future<void> _refreshAfterDone(String barcode, Stream<({String status, String? errorMessage})> status) async {
    await for (final s in status) {
      if (s.status == 'done') {
        for (final delay in _refreshDelaysAfterDone) {
          await Future.delayed(delay);
          await refreshSingleProduct(barcode);
        }
        return;
      }
      if (s.status == 'error') return;
    }
  }

  /// One-shot live re-fetch of a single product, used to force-refresh the
  /// local cache after we know (via a request's own status) that a change
  /// has landed server-side.
  Future<void> refreshSingleProduct(String barcode) async {
    try {
      final row = await _client
          .from('products')
          .select('barcode, pluno, stockname, price, depno, stockunit, search_key, kdv_rate')
          .eq('barcode', barcode)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (row != null) await _localDb.upsertSingleProduct(Product.fromJson(row));
    } catch (_) {
      // Best-effort -- the periodic safety-net refresh and realtime channel
      // still cover it eventually.
    }
  }

  // ---- send history ("Eski Gönderilenler") -- both request-queue tables
  // already keep every row forever, so this is just a read of whatever's
  // reached a final status, no separate log needed.

  Future<List<SentChangeRecord>> getRecentSentChanges({int limit = 20}) async {
    try {
      final priceRows = await _client
          .from('price_update_requests')
          .select('barcode, new_price, old_price, status, error_message, requested_by, created_at, processed_at, '
              'products(stockname)')
          .neq('status', 'pending')
          .neq('status', 'processing')
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 5));
      final fieldRows = await _client
          .from('product_field_update_requests')
          .select('barcode, field, new_value, old_value, status, error_message, requested_by, created_at, '
              'processed_at, products(stockname)')
          .neq('status', 'pending')
          .neq('status', 'processing')
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 5));

      final records = <SentChangeRecord>[
        for (final r in priceRows)
          SentChangeRecord(
            barcode: r['barcode'] as String,
            stockname: (r['products'] as Map?)?['stockname'] as String?,
            field: 'price',
            newValue: (r['new_price'] as num).toString(),
            oldValue: (r['old_price'] as num?)?.toString(),
            status: r['status'] as String,
            errorMessage: r['error_message'] as String?,
            requestedBy: r['requested_by'] as String?,
            at: DateTime.parse((r['processed_at'] ?? r['created_at']) as String),
          ),
        for (final r in fieldRows)
          SentChangeRecord(
            barcode: r['barcode'] as String,
            stockname: (r['products'] as Map?)?['stockname'] as String?,
            field: r['field'] as String,
            newValue: r['new_value'] as String,
            oldValue: r['old_value'] as String?,
            status: r['status'] as String,
            errorMessage: r['error_message'] as String?,
            requestedBy: r['requested_by'] as String?,
            at: DateTime.parse((r['processed_at'] ?? r['created_at']) as String),
          ),
      ]..sort((a, b) => b.at.compareTo(a.at));

      return records.take(limit).toList();
    } catch (_) {
      return [];
    }
  }
}
