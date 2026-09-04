import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../format.dart';
import '../kasa_repo.dart';
import '../models.dart';
import '../platform_util.dart';
import '../theme.dart';
import '../widgets/product_sales_table.dart';
import '../widgets/sortable_table.dart';

String _qty(num? q) {
  if (q == null) return '-';
  return q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);
}

String _dmy(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

const _monthsTr = [
  'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
];

String _dm(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day} ${_monthsTr[d.month - 1]}';
}

enum _KasapPreset { today, last7, last30, last90, thisMonth, lastMonth, custom }

/// Sales stats scoped to a resolved barcode set (Kasap: SARKUTERI PLU
/// 50-100; Manav: MANAV PLU 1-44). This is the "Ürün Satışları" tab content
/// for both -- summary + product table (same ProductSalesReportTable
/// widget, so the sold/iptal drill-down on row-tap works here too), plus a
/// daily qty/revenue trend below it. Reused in three places: nested as an
/// İstatistik tab (mobile, Furkan/Ahmet only -- see istatistik_screen.dart),
/// and as one of [ScopedStatsBody]'s five tabs (desktop top-level sections,
/// and Ramazan's standalone Kasap destination).
class KasapContent extends StatefulWidget {
  final KasaRepo repo;
  final Future<Set<String>> Function() barcodesResolver;
  final String emptyMessage;
  const KasapContent({
    super.key,
    required this.repo,
    required this.barcodesResolver,
    this.emptyMessage = 'Barkod seti bulunamadı.',
  });

  @override
  State<KasapContent> createState() => _KasapContentState();
}

class _KasapContentState extends State<KasapContent> {
  // null = still resolving the barcode set; empty = resolved, none found.
  Set<String>? _barcodes;
  _KasapPreset _preset = _KasapPreset.last30;
  late DateTime _from;
  late DateTime _to;
  Future<List<KasaProductSalesReport>>? _reportFuture;
  Future<List<KasaDailyTrendPoint>>? _trendFuture;

  @override
  void initState() {
    super.initState();
    _computeDatesForPreset(_preset);
    widget.barcodesResolver().then((barcodes) {
      if (!mounted) return;
      setState(() {
        _barcodes = barcodes;
        _reload();
      });
    });
  }

  void _computeDatesForPreset(_KasapPreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (preset) {
      case _KasapPreset.today:
        _from = today;
        _to = today;
      case _KasapPreset.last7:
        _from = today.subtract(const Duration(days: 6));
        _to = today;
      case _KasapPreset.last30:
        _from = today.subtract(const Duration(days: 29));
        _to = today;
      case _KasapPreset.last90:
        _from = today.subtract(const Duration(days: 89));
        _to = today;
      case _KasapPreset.thisMonth:
        _from = DateTime(now.year, now.month, 1);
        _to = today;
      case _KasapPreset.lastMonth:
        final firstOfThisMonth = DateTime(now.year, now.month, 1);
        final lastOfPrevMonth = firstOfThisMonth.subtract(const Duration(days: 1));
        _from = DateTime(lastOfPrevMonth.year, lastOfPrevMonth.month, 1);
        _to = lastOfPrevMonth;
      case _KasapPreset.custom:
        break;
    }
  }

  void _reload() {
    final list = (_barcodes ?? const {}).toList();
    _reportFuture = widget.repo.getProductSalesReport(
      from: _from,
      to: _to,
      barcodes: list,
      includeUnsold: true,
      limit: 1000,
    );
    _trendFuture = widget.repo.getProductSalesDailyTrend(from: _from, to: _to, barcodes: list);
  }

  void _selectPreset(_KasapPreset preset) {
    setState(() {
      _preset = preset;
      _computeDatesForPreset(preset);
      _reload();
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final initial = DateTimeRange(
      start: _from.isAfter(now) ? now : _from,
      end: _to.isAfter(now) ? now : _to,
    );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 450)),
      lastDate: now,
      initialDateRange: initial,
      helpText: 'Tarih Aralığı Seçin',
      cancelText: 'Vazgeç',
      confirmText: 'Uygula',
      saveText: 'Uygula',
    );
    if (picked != null) {
      setState(() {
        _preset = _KasapPreset.custom;
        _from = picked.start;
        _to = picked.end;
        _reload();
      });
    }
  }

  String _presetLabel(_KasapPreset p) => switch (p) {
        _KasapPreset.today => 'Bugün',
        _KasapPreset.last7 => 'Son 7 gün',
        _KasapPreset.last30 => 'Son 30 gün',
        _KasapPreset.last90 => 'Son 90 gün',
        _KasapPreset.thisMonth => 'Bu Ay',
        _KasapPreset.lastMonth => 'Geçen Ay',
        _KasapPreset.custom => '${_dm(_from)} - ${_dm(_to)}',
      };

  @override
  Widget build(BuildContext context) {
    if (_barcodes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_barcodes!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            widget.emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.brown500),
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Zaman:',
                    style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600, fontSize: 12.5)),
                for (final p in [
                  _KasapPreset.today,
                  _KasapPreset.last7,
                  _KasapPreset.last30,
                  _KasapPreset.last90,
                  _KasapPreset.thisMonth,
                  _KasapPreset.lastMonth,
                ])
                  ChoiceChip(
                    label: Text(_presetLabel(p)),
                    selected: _preset == p,
                    onSelected: (_) => _selectPreset(p),
                    selectedColor: AppColors.terracotta,
                    labelStyle: TextStyle(
                      color: _preset == p ? Colors.white : AppColors.brown700,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: AppColors.brown100,
                  ),
                ActionChip(
                  label: Text(_preset == _KasapPreset.custom ? _presetLabel(_preset) : 'Özel'),
                  onPressed: _pickCustomRange,
                  backgroundColor:
                      _preset == _KasapPreset.custom ? AppColors.terracotta : AppColors.brown100,
                  labelStyle: TextStyle(
                    color: _preset == _KasapPreset.custom ? Colors.white : AppColors.brown700,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<KasaProductSalesReport>>(
              future: _reportFuture,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 50),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final rows = snap.data!;
                num totalQty = 0;
                num totalRevenue = 0;
                int totalLines = 0;
                for (final r in rows) {
                  totalQty += r.qty;
                  totalRevenue += r.revenue;
                  totalLines += r.lineCount;
                }

                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.creamCard,
                          borderRadius: BorderRadius.circular(AppRadius.box),
                          border: Border.all(color: AppColors.creamBorder),
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('${rows.length} ürün listeleniyor',
                                style: const TextStyle(
                                    color: AppColors.brown800, fontSize: 12.5, fontWeight: FontWeight.w700)),
                            Text(
                              'Toplam: ${_qty(totalQty)} adet  ·  ${formatPrice(totalRevenue)}  ·  $totalLines işlem',
                              style: const TextStyle(
                                  color: AppColors.terracotta, fontSize: 12.5, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        flex: 2,
                        child: ProductSalesReportTable(
                          rows: rows,
                          pageSize: appSettings.tablePageSize,
                          from: _from,
                          to: _to,
                          repo: widget.repo,
                          compact: !isDesktopPlatform,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('Günlük Trend',
                          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown700, fontSize: 13)),
                      const SizedBox(height: 6),
                      Expanded(
                        flex: 1,
                        child: FutureBuilder<List<KasaDailyTrendPoint>>(
                          future: _trendFuture,
                          builder: (context, trendSnap) {
                            if (!trendSnap.hasData) {
                              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                            }
                            final points = trendSnap.data!;
                            return SortableTable<KasaDailyTrendPoint>(
                              rows: points,
                              pageSize: appSettings.tablePageSize,
                              initialSortColumn: 0,
                              initialAscending: false,
                              emptyText: 'Bu aralıkta günlük satış yok.',
                              columns: [
                                SortColumn(
                                  label: 'Tarih',
                                  flex: 2,
                                  sortKey: (d) => d.date.millisecondsSinceEpoch,
                                  cell: (d) => Text(_dmy(d.date)),
                                ),
                                SortColumn(
                                  label: 'Adet',
                                  width: 90,
                                  numeric: true,
                                  sortKey: (d) => d.qty,
                                  cell: (d) => Text(_qty(d.qty)),
                                ),
                                SortColumn(
                                  label: 'Ciro',
                                  width: 110,
                                  numeric: true,
                                  sortKey: (d) => d.revenue,
                                  cell: (d) => Text(
                                    formatPrice(d.revenue),
                                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.terracotta),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
