import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'models.dart';
import 'normalize.dart';

class DataRepo {
  SupabaseClient get _client => Supabase.instance.client;

  bool get isSignedIn => _client.auth.currentSession != null;

  /// Staff enter just the shared password; the fixed shared-account email
  /// is an implementation detail they never see.
  Future<void> signIn(String password) async {
    await _client.auth.signInWithPassword(
      email: sharedStaffEmail,
      password: password,
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<Product?> lookupBarcode(String barcode) async {
    final row = await _client
        .from('products')
        .select('barcode, pluno, stockname, price, depno, stockunit')
        .eq('barcode', barcode.trim())
        .maybeSingle();
    return row == null ? null : Product.fromJson(row);
  }

  Future<List<Product>> searchProducts(String query) async {
    final normalized = normalizeTurkish(query).replaceAll(RegExp(r'[,()%_]'), ' ').trim();
    final digits = query.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalized.isEmpty && digits.isEmpty) return [];

    final filters = <String>[];
    if (normalized.isNotEmpty) filters.add('search_key.ilike.%$normalized%');
    if (digits.isNotEmpty) filters.add('barcode.ilike.%$digits%');

    final rows = await _client
        .from('products')
        .select('barcode, pluno, stockname, price, depno, stockunit')
        .or(filters.join(','))
        .limit(20);
    return (rows as List).map((r) => Product.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<List<ProductList>> getLists() async {
    final rows = await _client
        .from('lists')
        .select('id, name, type, fields, created_at')
        .order('created_at', ascending: false);
    return (rows as List).map((r) => ProductList.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<ProductList> createList(String name, ListKind type, List<CustomField> fields) async {
    final row = await _client
        .from('lists')
        .insert({
          'name': name,
          'type': type.dbValue,
          'fields': fields.map((f) => f.toJson()).toList(),
        })
        .select('id, name, type, fields, created_at')
        .single();
    return ProductList.fromJson(row);
  }

  Future<void> deleteList(String id) => _client.from('lists').delete().eq('id', id);

  Future<ProductList> getListById(String id) async {
    final row = await _client
        .from('lists')
        .select('id, name, type, fields, created_at')
        .eq('id', id)
        .single();
    return ProductList.fromJson(row);
  }

  /// Live-updating list of lists. Supabase's `.stream()` can't express the
  /// `products(...)` join `getLists()`/`getListItems()` use, so this just
  /// uses the raw realtime stream as a "something changed" signal and
  /// re-runs the properly-joined query each time -- correct and simple,
  /// at the cost of an extra round trip per change (fine at this scale).
  Stream<List<ProductList>> watchLists() async* {
    yield await getLists();
    await for (final _ in _client.from('lists').stream(primaryKey: ['id'])) {
      yield await getLists();
    }
  }

  Stream<List<ListItem>> watchListItems(String listId) async* {
    yield await getListItems(listId);
    await for (final _ in _client
        .from('list_items')
        .stream(primaryKey: ['id'])
        .eq('list_id', listId)) {
      yield await getListItems(listId);
    }
  }

  static const _itemSelect =
      'id, list_id, barcode, quantity, new_price, note, custom_data, scanned_at, products(barcode, pluno, stockname, price, depno, stockunit)';

  Future<List<ListItem>> getListItems(String listId) async {
    final rows = await _client
        .from('list_items')
        .select(_itemSelect)
        .eq('list_id', listId)
        .order('scanned_at', ascending: false);
    return (rows as List).map((r) => ListItem.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<ListItem> addListItem(String listId, String barcode) async {
    final row = await _client
        .from('list_items')
        .insert({'list_id': listId, 'barcode': barcode})
        .select(_itemSelect)
        .single();
    return ListItem.fromJson(row);
  }

  /// Each screen only ever updates the one field its list type uses, so the
  /// caller passes exactly that field (nullable, to allow clearing it) and
  /// leaves the rest as sentinel-unset.
  Future<void> updateItemQuantity(String itemId, num? quantity) =>
      _client.from('list_items').update({'quantity': quantity}).eq('id', itemId);

  Future<void> updateItemNewPrice(String itemId, num? newPrice) =>
      _client.from('list_items').update({'new_price': newPrice}).eq('id', itemId);

  Future<void> updateItemNote(String itemId, String? note) =>
      _client.from('list_items').update({'note': note}).eq('id', itemId);

  Future<void> updateItemCustomData(String itemId, Map<String, dynamic> customData) =>
      _client.from('list_items').update({'custom_data': customData}).eq('id', itemId);

  Future<void> deleteListItem(String itemId) =>
      _client.from('list_items').delete().eq('id', itemId);

  /// Same shape as the old backend's /api/listelerim/[id]/csv route, built
  /// client-side now that there's no server.
  String buildCsv(ProductList list, List<ListItem> items) {
    String esc(Object? v) {
      final s = v?.toString() ?? '';
      if (s.contains(RegExp(r'[",\n]'))) return '"${s.replaceAll('"', '""')}"';
      return s;
    }

    final baseHeaders = ['Barkod', 'Ürün Adı', 'Fiyat', 'Birim'];
    final List<String> extraHeaders = switch (list.type) {
      ListKind.restock => ['Miktar'],
      ListKind.priceChange => ['Yeni Fiyat'],
      ListKind.priceCheck => ['Not'],
      ListKind.custom => list.fields.map((f) => f.label).toList(),
    };

    final rows = items.map((item) {
      final base = [
        item.barcode,
        item.product?.stockname ?? '',
        item.product?.price ?? '',
        item.product?.stockunit ?? '',
      ];
      final List<Object?> extra = switch (list.type) {
        ListKind.restock => [item.quantity ?? ''],
        ListKind.priceChange => [item.newPrice ?? ''],
        ListKind.priceCheck => [item.note ?? ''],
        ListKind.custom => list.fields.map((f) => item.customData[f.key] ?? '').toList(),
      };
      return [...base, ...extra];
    });

    final lines = [
      [...baseHeaders, ...extraHeaders].map(esc).join(','),
      ...rows.map((r) => r.map(esc).join(',')),
    ];
    return '﻿${lines.join('\r\n')}';
  }
}
