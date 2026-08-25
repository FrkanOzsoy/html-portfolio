import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'models.dart';

/// On-device cache that the rest of the app reads from and writes to
/// directly -- this is what makes the app usable with no internet. Lists and
/// list items created/edited offline are written here immediately and their
/// remote counterpart is driven by [SyncEngine] through the `pending_ops`
/// queue below; nothing here talks to Supabase.
///
/// Rows referenced by a still-pending op are "protected": a remote pull/
/// realtime merge must not overwrite or resurrect-delete them, since that
/// would clobber an edit that hasn't reached the server yet. Once the op
/// flushes successfully and is removed from the queue, the row is fair game
/// for the next merge again.
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;
  final _changesController = StreamController<void>.broadcast();
  Stream<void> get changes => _changesController.stream;
  void _notify() => _changesController.add(null);

  Future<Database> get _d async {
    if (_db != null) return _db!;
    // sqflite_common_ffi's own getDatabasesPath() defaults to
    // "<current working directory>/.dart_tool/sqflite_common_ffi/databases"
    // -- fine for `flutter run`, but for a packaged exe the working
    // directory is wherever it happened to be launched from. Launched
    // straight out of a zip/archive viewer (no extract-first), that's a
    // fresh temp folder deleted after the process exits -- so lists, the
    // product cache, staged changes, and the offline write queue all
    // silently reset on every single run, never actually persisting.
    // A real per-user app-data directory (same idea as Android's own
    // getDatabasesPath()) fixes that regardless of how the exe is launched.
    final dir = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? (await getApplicationSupportDirectory()).path
        : await getDatabasesPath();
    final path = p.join(dir, 'barkod_local.db');
    _db = await openDatabase(
      path,
      version: 4,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "alter table list_items_cache add column pending_product_changes text not null default '{}'",
          );
        }
        if (oldVersion < 4) {
          await db.execute('alter table products_cache add column kdv_rate real');
        }
        if (oldVersion < 3) {
          // Superseded by product_pending_changes below (staging is no
          // longer list-item-scoped) -- the old column is left in place
          // unused rather than dropped, since older bundled SQLite builds
          // don't all support ALTER TABLE ... DROP COLUMN.
          await db.execute('''
            create table if not exists product_pending_changes_cache(
              id text primary key,
              barcode text not null,
              field text not null,
              new_value text not null,
              source_list_id text,
              source_list_name text,
              requested_by text,
              created_at text not null
            )
          ''');
          await db.execute(
            'create index if not exists product_pending_changes_cache_barcode_idx '
            'on product_pending_changes_cache(barcode)',
          );
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          create table products_cache(
            barcode text primary key,
            pluno text,
            stockname text not null,
            price real,
            depno text,
            stockunit text,
            search_key text not null default '',
            kdv_rate real
          )
        ''');
        await db.execute('create index products_cache_search_idx on products_cache(search_key)');
        await db.execute('''
          create table lists_cache(
            id text primary key,
            name text not null,
            type text not null,
            fields text not null default '[]',
            created_at text not null
          )
        ''');
        await db.execute('''
          create table list_items_cache(
            id text primary key,
            list_id text not null,
            barcode text not null,
            quantity real,
            new_price real,
            note text,
            custom_data text not null default '{}',
            scanned_at text not null
          )
        ''');
        await db.execute('create index list_items_cache_list_idx on list_items_cache(list_id)');
        await db.execute('''
          create table product_pending_changes_cache(
            id text primary key,
            barcode text not null,
            field text not null,
            new_value text not null,
            source_list_id text,
            source_list_name text,
            requested_by text,
            created_at text not null
          )
        ''');
        await db.execute(
          'create index product_pending_changes_cache_barcode_idx on product_pending_changes_cache(barcode)',
        );
        await db.execute('''
          create table pending_ops(
            id integer primary key autoincrement,
            kind text not null,
            payload text not null,
            created_at text not null
          )
        ''');
      },
    );
    return _db!;
  }

  // ---- products ----

  Future<void> replaceAllProducts(List<Product> products) async {
    final db = await _d;
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete('products_cache');
      for (final prod in products) {
        batch.insert('products_cache', _productToRow(prod));
      }
      await batch.commit(noResult: true);
    });
    _notify();
  }

  /// Whether the local catalog actually has anything in it -- used by
  /// SyncEngine to decide whether a "last synced at" watermark in
  /// SharedPreferences can be trusted. Those two stores don't share a
  /// lifecycle: SharedPreferences can persist across a SQLite file being
  /// relocated/reset (a fresh Windows install after the local-db path fix,
  /// clearing app data, a corrupted db file being rebuilt), leaving a
  /// watermark that claims "already fully synced" against a products_cache
  /// that's actually empty -- which made pullProducts() only fetch tiny
  /// incremental slices instead of ever doing the real full download.
  Future<bool> hasAnyProducts() async {
    final db = await _d;
    final rows = await db.rawQuery('select 1 from products_cache limit 1');
    return rows.isNotEmpty;
  }

  /// Single-row upsert/delete, used by SyncEngine's realtime subscription on
  /// `products` so a price/name change made directly in Digisoft (not
  /// through this app) shows up here within moments, without waiting for
  /// the next full [replaceAllProducts] pass.
  Future<void> upsertSingleProduct(Product product) async {
    final db = await _d;
    await db.insert('products_cache', _productToRow(product), conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> deleteProductLocal(String barcode) async {
    final db = await _d;
    await db.delete('products_cache', where: 'barcode = ?', whereArgs: [barcode]);
    _notify();
  }

  Future<Product?> lookupProductLocal(String barcode) async {
    final db = await _d;
    final rows = await db.query('products_cache', where: 'barcode = ?', whereArgs: [barcode]);
    if (rows.isEmpty) return null;
    return _rowToProduct(rows.first);
  }

  /// Bulk variant for the Excel import review screen -- a supplier price
  /// list can be hundreds of rows, and looking each one up one at a time
  /// would mean hundreds of round trips into sqflite. Chunked at 500 to
  /// stay well under SQLite's default ~999 bound-parameter limit.
  Future<Map<String, Product>> lookupProductsLocal(List<String> barcodes) async {
    if (barcodes.isEmpty) return {};
    final db = await _d;
    final result = <String, Product>{};
    for (var i = 0; i < barcodes.length; i += 500) {
      final chunk = barcodes.sublist(i, i + 500 > barcodes.length ? barcodes.length : i + 500);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query('products_cache', where: 'barcode in ($placeholders)', whereArgs: chunk);
      for (final row in rows) {
        final p = _rowToProduct(row);
        result[p.barcode] = p;
      }
    }
    return result;
  }

  Future<List<Product>> searchProductsLocal(String normalizedQuery, String digits) async {
    final db = await _d;
    final where = <String>[];
    final args = <Object?>[];
    if (normalizedQuery.isNotEmpty) {
      where.add('search_key like ?');
      args.add('%$normalizedQuery%');
    }
    if (digits.isNotEmpty) {
      where.add('barcode like ?');
      args.add('%$digits%');
    }
    if (where.isEmpty) return [];

    // A name *starting with* the query ranks ahead of one that merely
    // *contains* it somewhere in the middle -- without this, "%query%"
    // with no ordering returns whatever 20 rows the scan happens to hit
    // first, so a short query (typing the first couple of letters of a
    // product name) could surface an unrelated product whose name just
    // happens to contain that substring elsewhere (e.g. "ko" matching
    // "...(KOPYA)" on a totally different product) ahead of the actual
    // prefix match -- which reads as the search lagging/showing stale
    // results even though it answered instantly.
    var orderBy = 'stockname';
    if (normalizedQuery.isNotEmpty) {
      args.add('$normalizedQuery%');
      orderBy = '(case when search_key like ? then 0 else 1 end), stockname';
    }
    final rows = await db.rawQuery(
      'select * from products_cache where ${where.join(' or ')} order by $orderBy limit 200',
      args,
    );
    return rows.map(_rowToProduct).toList();
  }

  Map<String, dynamic> _productToRow(Product prod) => {
        'barcode': prod.barcode,
        'pluno': prod.pluno,
        'stockname': prod.stockname,
        'price': prod.price,
        'depno': prod.depno,
        'stockunit': prod.stockunit,
        'search_key': prod.searchKey ?? '',
        'kdv_rate': prod.kdvRate,
      };

  Product _rowToProduct(Map<String, Object?> row) => Product(
        barcode: row['barcode'] as String,
        pluno: row['pluno'] as String?,
        stockname: row['stockname'] as String,
        price: row['price'] as num?,
        depno: row['depno'] as String?,
        stockunit: row['stockunit'] as String?,
        searchKey: row['search_key'] as String?,
        kdvRate: row['kdv_rate'] as num?,
      );

  // ---- lists ----

  Future<List<ProductList>> getLists() async {
    final db = await _d;
    final rows = await db.query('lists_cache', orderBy: 'created_at desc');
    return rows.map(_rowToList).toList();
  }

  Future<ProductList?> getListById(String id) async {
    final db = await _d;
    final rows = await db.query('lists_cache', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _rowToList(rows.first);
  }

  Future<void> upsertListLocal(ProductList list) async {
    final db = await _d;
    await db.insert('lists_cache', _listToRow(list), conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> hardDeleteListAndItems(String id) async {
    final db = await _d;
    await db.delete('lists_cache', where: 'id = ?', whereArgs: [id]);
    await db.delete('list_items_cache', where: 'list_id = ?', whereArgs: [id]);
    _notify();
  }

  Future<void> mergeRemoteLists(List<ProductList> remoteLists) async {
    final db = await _d;
    final protectedIds = await _protectedIds({'create_list', 'delete_list'});
    await db.transaction((txn) async {
      for (final list in remoteLists) {
        if (protectedIds.contains(list.id)) continue;
        await txn.insert('lists_cache', _listToRow(list), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final remoteIds = remoteLists.map((l) => l.id).toSet();
      final localRows = await txn.query('lists_cache', columns: ['id']);
      for (final row in localRows) {
        final id = row['id'] as String;
        if (protectedIds.contains(id) || remoteIds.contains(id)) continue;
        await txn.delete('lists_cache', where: 'id = ?', whereArgs: [id]);
        await txn.delete('list_items_cache', where: 'list_id = ?', whereArgs: [id]);
      }
    });
    _notify();
  }

  Map<String, dynamic> _listToRow(ProductList list) => {
        'id': list.id,
        'name': list.name,
        'type': list.type.dbValue,
        'fields': jsonEncode(list.fields.map((f) => f.toJson()).toList()),
        'created_at': list.createdAt.toIso8601String(),
      };

  ProductList _rowToList(Map<String, Object?> row) => ProductList(
        id: row['id'] as String,
        name: row['name'] as String,
        type: ListKindX.fromDb(row['type'] as String),
        fields: (jsonDecode(row['fields'] as String) as List)
            .map((f) => CustomField.fromJson((f as Map).cast<String, dynamic>()))
            .toList(),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  // ---- list items ----

  Future<List<ListItem>> getListItems(String listId) async {
    final db = await _d;
    final rows = await db.rawQuery('''
      select li.*, p.pluno as p_pluno, p.stockname as p_stockname, p.price as p_price,
             p.depno as p_depno, p.stockunit as p_stockunit
      from list_items_cache li
      left join products_cache p on p.barcode = li.barcode
      where li.list_id = ?
      order by li.scanned_at desc
    ''', [listId]);
    return rows.map(_rowToListItem).toList();
  }

  Future<void> upsertItemLocal(ListItem item) async {
    final db = await _d;
    await db.insert('list_items_cache', _itemToRow(item), conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> updateItemFieldLocal(String id, String field, dynamic value) async {
    final db = await _d;
    final columnValue = field == 'custom_data' ? jsonEncode(value) : value;
    await db.update('list_items_cache', {field: columnValue}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<void> hardDeleteItem(String id) async {
    final db = await _d;
    await db.delete('list_items_cache', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<void> mergeRemoteItems(List<ListItem> remoteItems) async {
    final db = await _d;
    final protectedIds = await _protectedIds({'add_item', 'update_item', 'delete_item'});
    await db.transaction((txn) async {
      for (final item in remoteItems) {
        if (protectedIds.contains(item.id)) continue;
        await txn.insert('list_items_cache', _itemToRow(item), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final remoteIds = remoteItems.map((i) => i.id).toSet();
      final localRows = await txn.query('list_items_cache', columns: ['id']);
      for (final row in localRows) {
        final id = row['id'] as String;
        if (protectedIds.contains(id) || remoteIds.contains(id)) continue;
        await txn.delete('list_items_cache', where: 'id = ?', whereArgs: [id]);
      }
    });
    _notify();
  }

  Map<String, dynamic> _itemToRow(ListItem item) => {
        'id': item.id,
        'list_id': item.listId,
        'barcode': item.barcode,
        'quantity': item.quantity,
        'new_price': item.newPrice,
        'note': item.note,
        'custom_data': jsonEncode(item.customData),
        'scanned_at': item.scannedAt.toIso8601String(),
      };

  ListItem _rowToListItem(Map<String, Object?> row) => ListItem(
        id: row['id'] as String,
        listId: row['list_id'] as String,
        barcode: row['barcode'] as String,
        quantity: row['quantity'] as num?,
        newPrice: row['new_price'] as num?,
        note: row['note'] as String?,
        customData: (jsonDecode(row['custom_data'] as String) as Map).cast<String, dynamic>(),
        scannedAt: DateTime.parse(row['scanned_at'] as String),
        product: row['p_stockname'] != null
            ? Product(
                barcode: row['barcode'] as String,
                pluno: row['p_pluno'] as String?,
                stockname: row['p_stockname'] as String,
                price: row['p_price'] as num?,
                depno: row['p_depno'] as String?,
                stockunit: row['p_stockunit'] as String?,
              )
            : null,
      );

  // ---- staged product edits (not tied to a list -- see PendingChange) ----

  Future<void> upsertPendingChangeLocal(PendingChange change) async {
    final db = await _d;
    await db.insert('product_pending_changes_cache', _pendingChangeToRow(change),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> deletePendingChangeLocal(String id) async {
    final db = await _d;
    await db.delete('product_pending_changes_cache', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<List<PendingChange>> getPendingChangesForBarcode(String barcode) async {
    final db = await _d;
    final rows =
        await db.query('product_pending_changes_cache', where: 'barcode = ?', whereArgs: [barcode]);
    return rows.map(_rowToPendingChange).toList();
  }

  /// Every staged edit across every product, joined with its current
  /// (unstaged) product data for the "old value" side of the comparison --
  /// feeds the "Kasaya Gönder" tab.
  Future<List<PendingChange>> getAllPendingChanges() async {
    final db = await _d;
    final rows = await db.rawQuery('''
      select c.*, p.pluno as p_pluno, p.stockname as p_stockname, p.price as p_price,
             p.depno as p_depno, p.stockunit as p_stockunit
      from product_pending_changes_cache c
      left join products_cache p on p.barcode = c.barcode
      order by c.created_at desc
    ''');
    return rows.map(_rowToPendingChange).toList();
  }

  Future<void> mergeRemotePendingChanges(List<PendingChange> remoteChanges) async {
    final db = await _d;
    final protectedIds = await _protectedIds({'stage_change', 'unstage_change'});
    await db.transaction((txn) async {
      for (final change in remoteChanges) {
        if (protectedIds.contains(change.id)) continue;
        await txn.insert('product_pending_changes_cache', _pendingChangeToRow(change),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final remoteIds = remoteChanges.map((c) => c.id).toSet();
      final localRows = await txn.query('product_pending_changes_cache', columns: ['id']);
      for (final row in localRows) {
        final id = row['id'] as String;
        if (protectedIds.contains(id) || remoteIds.contains(id)) continue;
        await txn.delete('product_pending_changes_cache', where: 'id = ?', whereArgs: [id]);
      }
    });
    _notify();
  }

  Map<String, dynamic> _pendingChangeToRow(PendingChange change) => {
        'id': change.id,
        'barcode': change.barcode,
        'field': change.field,
        'new_value': change.newValue,
        'source_list_id': change.sourceListId,
        'source_list_name': change.sourceListName,
        'requested_by': change.requestedBy,
        'created_at': change.createdAt.toIso8601String(),
      };

  PendingChange _rowToPendingChange(Map<String, Object?> row) => PendingChange(
        id: row['id'] as String,
        barcode: row['barcode'] as String,
        field: row['field'] as String,
        newValue: row['new_value'] as String,
        sourceListId: row['source_list_id'] as String?,
        sourceListName: row['source_list_name'] as String?,
        requestedBy: row['requested_by'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        product: row['p_stockname'] != null
            ? Product(
                barcode: row['barcode'] as String,
                pluno: row['p_pluno'] as String?,
                stockname: row['p_stockname'] as String,
                price: row['p_price'] as num?,
                depno: row['p_depno'] as String?,
                stockunit: row['p_stockunit'] as String?,
              )
            : null,
      );

  // ---- pending ops ----

  Future<void> enqueueOp(String kind, Map<String, dynamic> payload) async {
    final db = await _d;
    await db.insert('pending_ops', {
      'kind': kind,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> allPendingOps() async {
    final db = await _d;
    return db.query('pending_ops', orderBy: 'id asc');
  }

  Future<void> deletePendingOp(int id) async {
    final db = await _d;
    await db.delete('pending_ops', where: 'id = ?', whereArgs: [id]);
  }

  /// Number of writes made on this device that haven't reached Supabase
  /// yet (offline, or a transient failure waiting on the next retry) --
  /// surfaced in the UI so staff can tell "my edits are still local" apart
  /// from "my edits are sent and just waiting on the till-PC".
  Future<int> pendingOpsCount() async {
    final db = await _d;
    final rows = await db.rawQuery('select count(*) as c from pending_ops');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Removes a still-queued op for [id] of the given [kind] before it ever
  /// reaches Supabase, instead of letting it flush later. Used by
  /// [DataRepo.unstageChange]'s direct-delete fast path: without this, a
  /// change staged while offline (or in the brief window before the queue
  /// flushes) and then immediately unstaged would have nothing to delete
  /// remotely yet -- the direct delete silently no-ops, and the still-queued
  /// 'stage_change' op flushes afterwards and resurrects the very row that
  /// was just cancelled. Returns true if a matching queued op was found and
  /// removed.
  Future<bool> cancelQueuedOp(String kind, String id) async {
    final db = await _d;
    final rows = await db.query('pending_ops', where: 'kind = ?', whereArgs: [kind]);
    var removed = false;
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (payload['id'] == id) {
        await db.delete('pending_ops', where: 'id = ?', whereArgs: [row['id']]);
        removed = true;
      }
    }
    return removed;
  }

  Future<Set<String>> _protectedIds(Set<String> kinds) async {
    final ops = await allPendingOps();
    final ids = <String>{};
    for (final op in ops) {
      if (!kinds.contains(op['kind'] as String)) continue;
      final payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
      final id = payload['id'];
      if (id is String) ids.add(id);
    }
    return ids;
  }

  Future<void> clearAccountData() async {
    final db = await _d;
    await db.delete('lists_cache');
    await db.delete('list_items_cache');
    await db.delete('pending_ops');
    // products_cache is left intact -- the catalog isn't account-specific.
    _notify();
  }
}
