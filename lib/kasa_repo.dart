import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data_repo.dart';
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
      'discount_total, cancel_total, is_void, note, line_count, card_brand';

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
        .select('total, cash_total, card_total, discount_total, is_void, receipt_type, sold_at, line_count, card_brand')
        .eq('receipt_type', 'FIS')
        .gte('sold_at', start.toUtc().toIso8601String())
        .lt('sold_at', end.toUtc().toIso8601String())
        .timeout(const Duration(seconds: 10));

    if (rows.isEmpty) return KasaDaySummary.empty(start);

    var receiptCount = 0, voidCount = 0;
    num gross = 0, voidValue = 0, cash = 0, card = 0, discount = 0, items = 0;
    final byHour = List<num>.filled(24, 0);
    final cardByBrand = <String, num>{};

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
      final cardT = (r['card_total'] as num?) ?? 0;
      card += cardT;
      discount += (r['discount_total'] as num?) ?? 0;
      items += (r['line_count'] as num?) ?? 0;
      final h = DateTime.parse(r['sold_at'] as String).toLocal().hour;
      if (h >= 0 && h < 24) byHour[h] += total;
      if (cardT > 0) {
        final brand = (r['card_brand'] as String?)?.trim();
        final key = (brand == null || brand.isEmpty) ? 'Kart' : brand;
        cardByBrand[key] = (cardByBrand[key] ?? 0) + cardT;
      }
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
      cardByBrand: cardByBrand,
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

  /// Receipts that touched at least one of [barcodes] -- backs the scoped
  /// Son İşlemler/İptaller views inside Kasap/Manav. One-shot (via
  /// kasa_receipts_for_barcodes RPC, since a receipt/line join can't be
  /// expressed as a realtime `.stream()` the way watchRecentReceipts is),
  /// so these scoped views trade liveness for the ability to filter by
  /// barcode set. Whole receipts are returned even if only one line
  /// matched -- same approximation the rest of the scoped summary makes.
  Future<List<KasaReceipt>> getReceiptsForBarcodes({
    required List<String> barcodes,
    DateTime? from,
    DateTime? to,
    bool voidOnly = false,
    int limit = 60,
  }) async {
    if (barcodes.isEmpty) return [];
    final rows = await _client.rpc('kasa_receipts_for_barcodes', params: {
      'p_barcodes': barcodes,
      'p_from': from?.toUtc().toIso8601String(),
      'p_to': to?.toUtc().toIso8601String(),
      'p_void_only': voidOnly,
      'p_limit': limit,
    }).timeout(const Duration(seconds: 15));
    return (rows as List).map((r) => KasaReceipt.fromJson(r as Map<String, dynamic>)).toList();
  }

  /// Kasap-only portion of each receipt's total, for receipts that mix a
  /// Kasap item with something else in the same cart -- the receipt's own
  /// `total` column is the *whole* fiş. Powers both the Hesap tab's per-fiş
  /// amount and the "Kasap Tutarı" column on Son İşlemler/İptaller.
  Future<Map<int, num>> getScopedSubtotalsForReceipts({
    required List<int> receiptIds,
    required List<String> barcodes,
  }) async {
    if (receiptIds.isEmpty || barcodes.isEmpty) return {};
    final rows = await _client.rpc('kasa_receipt_scoped_subtotals', params: {
      'p_receipt_ids': receiptIds,
      'p_barcodes': barcodes,
    }).timeout(const Duration(seconds: 15));
    return {
      for (final r in (rows as List)) (r['receipt_id'] as num).toInt(): (r['subtotal'] as num?) ?? 0,
    };
  }

  // ---- Kasap "Hesap" (Ramazan's manual sales calculation) --------------

  Future<List<KasapManualSale>> getManualSales({DateTime? from, DateTime? to}) async {
    var q = _client.from('kasap_manual_sales').select();
    if (from != null) q = q.gte('sale_date', _dateOnly(from));
    if (to != null) q = q.lte('sale_date', _dateOnly(to));
    final rows = await q.order('sale_date', ascending: false).timeout(const Duration(seconds: 10));
    return (rows as List).map((r) => KasapManualSale.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<void> addManualSale({
    required String barcode,
    required String stockname,
    required DateTime saleDate,
    num? weight,
    required num price,
    String? note,
    String? createdBy,
  }) =>
      _client.from('kasap_manual_sales').insert({
        'barcode': barcode,
        'stockname': stockname,
        'sale_date': _dateOnly(saleDate),
        'weight': weight,
        'price': price,
        'note': note,
        'created_by': createdBy,
      });

  Future<void> deleteManualSale(String id) => _client.from('kasap_manual_sales').delete().eq('id', id);

  /// Receipt ids currently excluded from the Hesap calculation -- excluding
  /// a fiş there doesn't touch the receipt itself, it only hides it from
  /// this specific total/list (see db/2026-09-04_kasap_hesap.sql).
  Future<Set<int>> getExcludedReceiptIds() async {
    final rows = await _client.from('kasap_hesap_excluded_receipts').select('receipt_id').timeout(const Duration(seconds: 10));
    return {for (final r in (rows as List)) (r['receipt_id'] as num).toInt()};
  }

  Future<void> excludeReceiptFromHesap(int receiptId, {String? reason, String? excludedBy}) =>
      _client.from('kasap_hesap_excluded_receipts').upsert({
        'receipt_id': receiptId,
        'reason': reason,
        'excluded_by': excludedBy,
      });

  Future<void> includeReceiptInHesap(int receiptId) =>
      _client.from('kasap_hesap_excluded_receipts').delete().eq('receipt_id', receiptId);

  /// Exact, unlimited receipt-level aggregates for [barcodes] over a date
  /// range -- Fiş/Nakit/Kart/İndirim/İptal for Kasap/Manav's Özet tab and
  /// the header line on their Son İşlemler/İptaller tabs. Deliberately not
  /// derived from getReceiptsForBarcodes's (capped) row list -- this is a
  /// dedicated server-side aggregate so it's never silently truncated.
  Future<ScopedReceiptsSummary> getReceiptsSummaryForBarcodes({
    required List<String> barcodes,
    DateTime? from,
    DateTime? to,
  }) async {
    if (barcodes.isEmpty) return ScopedReceiptsSummary.empty;
    final rows = await _client.rpc('kasa_receipts_summary_for_barcodes', params: {
      'p_barcodes': barcodes,
      'p_from': from?.toUtc().toIso8601String(),
      'p_to': to?.toUtc().toIso8601String(),
    }).timeout(const Duration(seconds: 15));
    return ScopedReceiptsSummary.fromJson((rows as List).first as Map<String, dynamic>);
  }

  /// Hourly revenue for [barcodes] on a single local day -- zero-filled to
  /// 24 slots so it drops straight into the same _HourlyBars widget the
  /// real (unscoped) Günlük Özet uses.
  Future<List<num>> getHourlySalesForBarcodes({required List<String> barcodes, required DateTime day}) async {
    final byHour = List<num>.filled(24, 0);
    if (barcodes.isEmpty) return byHour;
    final rows = await _client.rpc('kasa_hourly_sales_for_barcodes', params: {
      'p_barcodes': barcodes,
      'p_day': _dateOnly(day),
    }).timeout(const Duration(seconds: 15));
    for (final r in (rows as List)) {
      final h = (r['hour'] as num).toInt();
      if (h >= 0 && h < 24) byHour[h] = (r['revenue'] as num?) ?? 0;
    }
    return byHour;
  }

  // ---- Fiyat Uyuşmazlığı -------------------------------------------------

  /// Live stream of *open* (unresolved) price mismatches, newest first.
  Stream<List<KasaPriceMismatch>> watchOpenMismatches({int limit = 100}) {
    return _client
        .from('kasa_price_mismatches')
        .stream(primaryKey: ['id'])
        .order('sold_at', ascending: false)
        .limit(limit)
        .map((rows) => rows.map((r) => KasaPriceMismatch.fromJson(r)).where((m) => !m.resolved).toList());
  }

  Future<List<KasaPriceMismatch>> getMismatches({bool includeResolved = false, int limit = 200}) async {
    var q = _client.from('kasa_price_mismatches').select();
    if (!includeResolved) q = q.eq('resolved', false);
    final rows = await q.order('sold_at', ascending: false).limit(limit).timeout(const Duration(seconds: 10));
    return rows.map((r) => KasaPriceMismatch.fromJson(r)).toList();
  }

  Future<void> setMismatchResolved(int id, bool resolved) =>
      _client.from('kasa_price_mismatches').update({'resolved': resolved}).eq('id', id);

  /// "Çözüldü" on a grouped mismatch row hard-deletes every mismatch on
  /// record for that barcode (not just the one shown), since the same
  /// product can have several -- one per sale it happened on -- and staff
  /// mean "this product is fixed now", not "this one specific sale is
  /// fixed". Deletes both resolved and unresolved rows for the barcode so
  /// the "Çözülenleri de göster" list doesn't keep old entries around for a
  /// product that's already been fully cleared.
  Future<void> deleteMismatchesForBarcode(String barcode) =>
      _client.from('kasa_price_mismatches').delete().eq('barcode', barcode);

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

  // ---- Ölü Stok / Ürün Satışları ------------------------------------

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

  /// Product sales report over an arbitrary date range (inclusive),
  /// via the kasa_product_sales_report RPC.
  Future<List<KasaProductSalesReport>> getProductSalesReport({
    required DateTime from,
    required DateTime to,
    String? depno,
    bool includeUnsold = true,
    int limit = 1000,
    // Scopes the report to just these barcodes (e.g. Kasap's SARKUTERI
    // PLU 50-100 set) -- explicitly set whenever non-null, even an empty
    // list, so a barcode set that resolved empty filters to zero rows
    // instead of silently falling back to "no filter" (the whole catalog).
    List<String>? barcodes,
  }) async {
    final params = <String, dynamic>{
      'p_from': _dateOnly(from),
      'p_to': _dateOnly(to),
      'p_include_unsold': includeUnsold,
      'p_limit': limit,
    };
    if (depno != null && depno.isNotEmpty) {
      params['p_depno'] = depno;
    }
    if (barcodes != null) {
      params['p_barcodes'] = barcodes;
    }
    final rows = await _client
        .rpc('kasa_product_sales_report', params: params)
        .timeout(const Duration(seconds: 20));
    return (rows as List)
        .map((r) => KasaProductSalesReport.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Sold vs. iptal breakdown for one product over a date range -- the
  /// drill-down shown when a Ürün Satışları / Kasap row is tapped.
  Future<SalesVoidBreakdown> getSalesVoidBreakdown({
    required String barcode,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _client.rpc('kasa_product_sales_void_breakdown', params: {
      'p_barcode': barcode,
      'p_from': _dateOnly(from),
      'p_to': _dateOnly(to),
    }).timeout(const Duration(seconds: 10));
    final row = (rows as List).first as Map<String, dynamic>;
    return SalesVoidBreakdown.fromJson(row);
  }

  /// Day-by-day qty/revenue trend for a barcode set (Kasap's "Günlük
  /// Trend") -- a plain client-side grouping of kasa_product_sales_daily
  /// rows, not an RPC, since it needs no products join.
  Future<List<KasaDailyTrendPoint>> getProductSalesDailyTrend({
    required DateTime from,
    required DateTime to,
    required List<String> barcodes,
  }) async {
    if (barcodes.isEmpty) return [];
    final rows = await _client
        .from('kasa_product_sales_daily')
        .select('sale_date, qty, revenue')
        .inFilter('barcode', barcodes)
        .gte('sale_date', _dateOnly(from))
        .lte('sale_date', _dateOnly(to))
        .timeout(const Duration(seconds: 15));
    final byDate = <String, ({num qty, num revenue})>{};
    for (final r in rows) {
      final date = r['sale_date'] as String;
      final prev = byDate[date] ?? (qty: 0, revenue: 0);
      byDate[date] = (
        qty: prev.qty + ((r['qty'] as num?) ?? 0),
        revenue: prev.revenue + ((r['revenue'] as num?) ?? 0),
      );
    }
    final points = [
      for (final e in byDate.entries)
        KasaDailyTrendPoint(date: DateTime.parse(e.key), qty: e.value.qty, revenue: e.value.revenue),
    ];
    points.sort((a, b) => a.date.compareTo(b.date));
    return points;
  }

  /// Distinct non-empty department codes (depno) from products table.
  Future<List<String>> getDistinctDepnos() async {
    try {
      final rows = await _client
          .from('products')
          .select('depno')
          .not('depno', 'is', null)
          .timeout(const Duration(seconds: 8));
      final depnos = <String>{};
      for (final r in rows) {
        final d = (r['depno'] as String?)?.trim();
        if (d != null && d.isNotEmpty) {
          depnos.add(d);
        }
      }
      final list = depnos.toList()..sort();
      return list;
    } catch (_) {
      return const [];
    }
  }

  // ---- receipt notes (staff-added, bound to belge_id) -----------------

  /// Live map of every receipt note, keyed by `belge_id`. Small table (only
  /// annotated receipts), so streaming the whole thing is fine -- lets a note
  /// added on one client show on every screen that lists that receipt.
  Stream<Map<String, KasaReceiptNote>> watchReceiptNotes() {
    return _client
        .from('kasa_receipt_notes')
        .stream(primaryKey: ['belge_id'])
        .map((rows) => {
              for (final r in rows)
                (r['belge_id'] as String): KasaReceiptNote.fromJson(r),
            });
  }

  /// Sets (or, with an empty string, clears) the note for one receipt.
  Future<void> setReceiptNote(String belgeId, String note) async {
    final trimmed = note.trim();
    if (trimmed.isEmpty) {
      await _client.from('kasa_receipt_notes').delete().eq('belge_id', belgeId);
      return;
    }
    final by = await DataRepo().getStaffName();
    await _client.from('kasa_receipt_notes').upsert({
      'belge_id': belgeId,
      'note': trimmed,
      'updated_by': by,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'belge_id');
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
