import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'local_db.dart';
import 'models.dart';

/// Read-only access to the kasa (INTER_BOS POS) mirror -- the `kasa_*` tables
/// the till-PC daemon keeps in step with the register. Nothing here writes
/// to the till; the one mutation is toggling `kasa_price_mismatches.resolved`
/// (a review flag, not till data).
///
/// Online-only, like messaging and the activity log -- these are monitoring
/// screens, not something needed offline, so there's no local cache or
/// pending-ops queue. Product *names* are resolved from the catalog cache
/// (kept fully synced on desktop) with a live fallback for anything missing.
class KasaRepo {
  SupabaseClient get _client => Supabase.instance.client;
  final _localDb = LocalDb.instance;

  static const _receiptCols =
      'id, belge_id, register_no, cashier_no, receipt_type, receipt_no, sold_at, '
      'closed_at, z_no, subtotal, vat_total, total, cash_total, card_total, '
      'discount_total, cancel_total, is_void, note, line_count';

  // ---- Son İşlemler: live receipt feed --------------------------------------

  /// Live stream of the most recent sale receipts, newest first. FIS only
  /// (report documents ZRP/XRP are filtered out client-side since the
  /// realtime stream can't).
  Stream<List<KasaReceipt>> watchRecentReceipts({int limit = 60}) {
    return _client
        .from('kasa_receipts')
        .stream(primaryKey: ['id'])
        .order('id', ascending: false)
        .limit(limit)
        .map((rows) => rows
            .map((r) => KasaReceipt.fromJson(r))
            .where((r) => r.isSale)
            .toList());
  }

  /// One page of receipts older than [beforeId] (for "load more" below the
  /// live window). FIS only.
  Future<List<KasaReceipt>> getReceiptsBefore(int beforeId, {int limit = 60}) async {
    final rows = await _client
        .from('kasa_receipts')
        .select(_receiptCols)
        .lt('id', beforeId)
        .eq('receipt_type', 'FIS')
        .order('id', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 8));
    return rows.map((r) => KasaReceipt.fromJson(r)).toList();
  }

  /// Lines + payments for one receipt, with product names resolved.
  Future<({List<KasaReceiptLine> lines, List<KasaPayment> payments})> getReceiptDetail(
      KasaReceipt receipt) async {
    final lineRows = await _client
        .from('kasa_receipt_lines')
        .select()
        .eq('belge_id', receipt.belgeId)
        .order('line_no')
        .timeout(const Duration(seconds: 8));
    final payRows = await _client
        .from('kasa_payments')
        .select()
        .eq('belge_id', receipt.belgeId)
        .order('line_no')
        .timeout(const Duration(seconds: 8));

    var lines = lineRows.map((r) => KasaReceiptLine.fromJson(r)).toList();
    lines = await _fillLineNames(lines);
    final payments = payRows.map((r) => KasaPayment.fromJson(r)).toList();
    return (lines: lines, payments: payments);
  }

  Future<List<KasaReceiptLine>> _fillLineNames(List<KasaReceiptLine> lines) async {
    final barcodes = lines.map((l) => l.barcode).whereType<String>().toSet().toList();
    if (barcodes.isEmpty) return lines;
    final byBarcode = await _resolveProducts(barcodes);
    return [
      for (final l in lines)
        if (l.name != null || l.barcode == null || byBarcode[l.barcode] == null)
          l
        else
          KasaReceiptLine(
            hareketId: l.hareketId,
            receiptId: l.receiptId,
            belgeId: l.belgeId,
            lineNo: l.lineNo,
            lineType: l.lineType,
            barcode: l.barcode,
            stockCode: l.stockCode,
            pluno: l.pluno,
            name: byBarcode[l.barcode]!.stockname,
            qty: l.qty,
            unitPrice: l.unitPrice,
            lineTotal: l.lineTotal,
            vatRate: l.vatRate,
            discountAmount: l.discountAmount,
            soldAt: l.soldAt,
          ),
    ];
  }

  /// Catalog lookup: local cache first (fully synced on desktop), then a
  /// single live query for whatever's still missing.
  Future<Map<String, Product>> _resolveProducts(List<String> barcodes) async {
    final result = <String, Product>{};
    try {
      result.addAll(await _localDb.lookupProductsLocal(barcodes));
    } catch (_) {}
    final missing = barcodes.where((b) => !result.containsKey(b)).toList();
    if (missing.isNotEmpty) {
      try {
        for (var i = 0; i < missing.length; i += 200) {
          final chunk = missing.sublist(i, (i + 200).clamp(0, missing.length));
          final rows = await _client
              .from('products')
              .select('barcode, pluno, stockname, price, depno, stockunit, search_key, kdv_rate')
              .inFilter('barcode', chunk)
              .timeout(const Duration(seconds: 6));
          for (final r in rows) {
            final p = Product.fromJson(r);
            result[p.barcode] = p;
          }
        }
      } catch (_) {}
    }
    return result;
  }

  // ---- Günlük Özet: one day's aggregate ------------------------------------

  /// Aggregates a single local day's receipts into a [KasaDaySummary].
  /// [day] is any DateTime within the target local day.
  Future<KasaDaySummary> getDaySummary(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await _client
        .from('kasa_receipts')
        .select('total, cash_total, card_total, discount_total, is_void, receipt_type, sold_at, line_count')
        .eq('receipt_type', 'FIS')
        .gte('sold_at', start.toUtc().toIso8601String())
        .lt('sold_at', end.toUtc().toIso8601String())
        .timeout(const Duration(seconds: 10));

    if (rows.isEmpty) return KasaDaySummary.empty(start);

    var receiptCount = 0, voidCount = 0;
    num gross = 0, voidValue = 0, cash = 0, card = 0, discount = 0, items = 0;
    final byHour = List<num>.filled(24, 0);

    for (final r in rows) {
      final isVoid = r['is_void'] as bool? ?? false;
      final total = (r['total'] as num?) ?? 0;
      if (isVoid) {
        voidCount++;
        voidValue += total;
        continue;
      }
      receiptCount++;
      gross += total;
      cash += (r['cash_total'] as num?) ?? 0;
      card += (r['card_total'] as num?) ?? 0;
      discount += (r['discount_total'] as num?) ?? 0;
      items += (r['line_count'] as num?) ?? 0;
      final h = DateTime.parse(r['sold_at'] as String).toLocal().hour;
      if (h >= 0 && h < 24) byHour[h] += total;
    }

    return KasaDaySummary(
      day: start,
      receiptCount: receiptCount,
      voidCount: voidCount,
      gross: gross,
      voidValue: voidValue,
      cash: cash,
      card: card,
      discount: discount,
      itemsSold: items,
      byHour: byHour,
    );
  }

  /// Top products for a single local day, straight off the daily roll-up,
  /// with names resolved. [day] is any DateTime within the target day.
  Future<List<KasaProductSales>> getTopProductsForDay(DateTime day, {int limit = 30}) async {
    final d = DateTime(day.year, day.month, day.day);
    final rows = await _client
        .from('kasa_product_sales_daily')
        .select('sale_date, barcode, qty, revenue, line_count, last_sold_at')
        .eq('sale_date', _dateOnly(d))
        .order('revenue', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 8));
    return _attachProducts(rows.map((r) => KasaProductSales.fromJson(r)).toList());
  }

  /// Top products over a local date range (inclusive), via the
  /// kasa_top_products RPC.
  Future<List<KasaProductSales>> getTopProductsRange(DateTime from, DateTime to, {int limit = 50}) async {
    final rows = await _client.rpc('kasa_top_products', params: {
      'p_from': _dateOnly(from),
      'p_to': _dateOnly(to),
      'p_limit': limit,
    }).timeout(const Duration(seconds: 12));
    return _attachProducts(
        (rows as List).map((r) => KasaProductSales.fromJson(r as Map<String, dynamic>)).toList());
  }

  Future<List<KasaProductSales>> _attachProducts(List<KasaProductSales> sales) async {
    final byBarcode = await _resolveProducts(sales.map((s) => s.barcode).toList());
    return [for (final s in sales) s.withProduct(byBarcode[s.barcode])];
  }

  // ---- İptaller: voided receipts ------------------------------------------

  Future<List<KasaReceipt>> getVoidReceipts({int daysBack = 30, int limit = 200}) async {
    final since = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await _client
        .from('kasa_receipts')
        .select(_receiptCols)
        .eq('is_void', true)
        .eq('receipt_type', 'FIS')
        .gte('sold_at', since.toUtc().toIso8601String())
        .order('sold_at', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 10));
    return rows.map((r) => KasaReceipt.fromJson(r)).toList();
  }

  // ---- Fiyat Uyuşmazlığı -------------------------------------------------

  /// Live stream of *open* (unresolved) price mismatches, newest first.
  Stream<List<KasaPriceMismatch>> watchOpenMismatches({int limit = 100}) {
    return _client
        .from('kasa_price_mismatches')
        .stream(primaryKey: ['id'])
        .order('sold_at', ascending: false)
        .limit(limit)
        .map((rows) => rows
            .map((r) => KasaPriceMismatch.fromJson(r))
            .where((m) => !m.resolved)
            .toList());
  }

  Future<List<KasaPriceMismatch>> getMismatches({bool includeResolved = false, int limit = 200}) async {
    var q = _client.from('kasa_price_mismatches').select();
    if (!includeResolved) q = q.eq('resolved', false);
    final rows = await q.order('sold_at', ascending: false).limit(limit).timeout(const Duration(seconds: 10));
    return rows.map((r) => KasaPriceMismatch.fromJson(r)).toList();
  }

  Future<void> setMismatchResolved(int id, bool resolved) =>
      _client.from('kasa_price_mismatches').update({'resolved': resolved}).eq('id', id);

  // ---- Z Raporları -----------------------------------------------------

  /// Ordered by `id` (monotonic) not `z_no` -- the register's Z counter can
  /// reset (fiscal-unit replacement), so `z_no` is not reliably chronological.
  Future<List<KasaZReport>> getZReports({int limit = 90}) async {
    final rows = await _client
        .from('kasa_zreports')
        .select('id, z_no, z_date, turnover, info')
        .order('id', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 10));
    return rows.map((r) => KasaZReport.fromJson(r)).toList();
  }

  // ---- Ölü Stok ------------------------------------------------------

  Future<List<KasaDeadStockItem>> getDeadStock({
    int days = 30,
    int limit = 300,
    bool requireHistory = true,
  }) async {
    final rows = await _client.rpc('kasa_dead_stock', params: {
      'p_days': days,
      'p_limit': limit,
      'p_require_history': requireHistory,
    }).timeout(const Duration(seconds: 15));
    return (rows as List).map((r) => KasaDeadStockItem.fromJson(r as Map<String, dynamic>)).toList();
  }

  // ---- freshness -----------------------------------------------------

  /// When the most recent mirrored receipt landed -- lets the screens show
  /// "kasa verisi X önce güncellendi" so a stalled daemon is obvious.
  Future<DateTime?> lastMirroredAt() async {
    try {
      final row = await _client
          .from('kasa_receipts')
          .select('synced_at')
          .order('id', ascending: false)
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      final raw = row?['synced_at'] as String?;
      return raw == null ? null : DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
