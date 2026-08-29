import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../format.dart';
import '../kasa_repo.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/add_to_list_button.dart';
import '../widgets/edit_product_button.dart';
import '../widgets/sortable_table.dart';

/// Desktop-only "İstatistik" tab -- a read-only window onto the register's
/// live sales, mirrored from INTER_BOS by the till-PC daemon (see
/// lib/kasa_repo.dart). Six sections, each with fully sortable tables:
///   Son İşlemler · Günlük Özet · İptaller · Fiyat Uyuşmazlığı ·
///   Z Raporları · Ölü Stok
class IstatistikScreen extends StatefulWidget {
  const IstatistikScreen({super.key});

  @override
  State<IstatistikScreen> createState() => _IstatistikScreenState();
}

class _IstatistikScreenState extends State<IstatistikScreen> with SingleTickerProviderStateMixin {
  final _repo = KasaRepo();
  late final TabController _tab = TabController(length: 6, vsync: this);

  int _openMismatches = 0;
  StreamSubscription? _mismatchSub;
  DateTime? _lastMirroredAt;
  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    _mismatchSub = _repo.watchOpenMismatches().listen((rows) {
      if (mounted) setState(() => _openMismatches = rows.length);
    });
    _refreshFreshness();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshFreshness());
  }

  Future<void> _refreshFreshness() async {
    final at = await _repo.lastMirroredAt();
    if (mounted) setState(() => _lastMirroredAt = at);
  }

  @override
  void dispose() {
    _mismatchSub?.cancel();
    _freshnessTimer?.cancel();
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.creamBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tab,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: AppColors.terracotta,
                    unselectedLabelColor: AppColors.brown600,
                    indicatorColor: AppColors.terracotta,
                    labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                    tabs: [
                      const Tab(text: 'Son İşlemler'),
                      const Tab(text: 'Günlük Özet'),
                      const Tab(text: 'İptaller'),
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Fiyat Uyuşmazlığı'),
                            if (_openMismatches > 0) ...[
                              const SizedBox(width: 6),
                              _CountPill(_openMismatches, color: AppColors.terracotta),
                            ],
                          ],
                        ),
                      ),
                      const Tab(text: 'Z Raporları'),
                      const Tab(text: 'Ölü Stok'),
                    ],
                  ),
                ),
                _FreshnessChip(at: _lastMirroredAt),
                const SizedBox(width: 12),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _ReceiptsSection(repo: _repo),
                _DaySummarySection(repo: _repo),
                _VoidsSection(repo: _repo),
                _MismatchSection(repo: _repo),
                _ZReportsSection(repo: _repo),
                _DeadStockSection(repo: _repo),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// shared helpers
// ===========================================================================

String _hm(DateTime utc) {
  final d = utc.toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

const _monthsTr = ['Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'];

String _dmy(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

String _dm(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day} ${_monthsTr[d.month - 1]}';
}

String _relativeTr(DateTime? utc) {
  if (utc == null) return 'bilinmiyor';
  final diff = DateTime.now().difference(utc.toLocal());
  if (diff.inSeconds < 60) return '${diff.inSeconds} sn önce';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dk önce';
  if (diff.inHours < 24) return '${diff.inHours} sa önce';
  return '${diff.inDays} gün önce';
}

String _qty(num? q) {
  if (q == null) return '-';
  return q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);
}

/// A meaningful payment label for a receipt: the mix of its own cash/card
/// totals rather than a raw tender code.
String _payLabel(KasaReceipt r) {
  final cash = r.cashTotal ?? 0;
  final card = r.cardTotal ?? 0;
  if (cash > 0 && card > 0) return 'Karışık';
  if (card > 0) return 'Kart';
  if (cash > 0) return 'Nakit';
  return '-';
}

class _CountPill extends StatelessWidget {
  final int count;
  final Color color;
  const _CountPill(this.count, {required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
        child: Text('$count',
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

class _FreshnessChip extends StatelessWidget {
  final DateTime? at;
  const _FreshnessChip({required this.at});

  @override
  Widget build(BuildContext context) {
    final stale = at == null || DateTime.now().difference(at!) > const Duration(minutes: 10);
    final color = stale ? AppColors.mustard : AppColors.success;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(stale ? Icons.sync_problem : Icons.sync, size: 13, color: color),
        const SizedBox(width: 5),
        Text('kasa: ${_relativeTr(at)}', style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

Padding _pad(Widget child) => Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), child: child);

/// Shared: open a product in a small sheet with the standard edit / add-to-list
/// actions (used from Ölü Stok and the top-products table).
Future<void> _peekProduct(BuildContext context, String barcode) async {
  final repo = DataRepo();
  final product = await repo.lookupBarcode(barcode);
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(product?.stockname ?? 'Ürün bulunamadı',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AppColors.brown900)),
          const SizedBox(height: 4),
          Text('$barcode${product?.price != null ? '  ·  ${formatPrice(product!.price)}' : ''}',
              style: const TextStyle(color: AppColors.brown500, fontSize: 13)),
          const SizedBox(height: 16),
          if (product != null)
            Row(
              children: [
                Expanded(child: EditProductButton(product: product)),
                const SizedBox(width: 10),
                Expanded(child: AddToListButton(product: product)),
              ],
            ),
        ],
      ),
    ),
  );
}

// ===========================================================================
// 1. Son İşlemler
// ===========================================================================

class _ReceiptsSection extends StatefulWidget {
  final KasaRepo repo;
  const _ReceiptsSection({required this.repo});

  @override
  State<_ReceiptsSection> createState() => _ReceiptsSectionState();
}

class _ReceiptsSectionState extends State<_ReceiptsSection> {
  final _older = <KasaReceipt>[];
  bool _loadingMore = false;

  Future<void> _loadMore(int oldestLiveId) async {
    setState(() => _loadingMore = true);
    final before = _older.isEmpty ? oldestLiveId : _older.last.id;
    final page = await widget.repo.getReceiptsBefore(before);
    setState(() {
      _older.addAll(page);
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<KasaReceipt>>(
      stream: widget.repo.watchRecentReceipts(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final live = snap.data!;
        final seen = <int>{};
        final all = [
          for (final r in [...live, ..._older])
            if (seen.add(r.id)) r,
        ];
        if (all.isEmpty) {
          return const _EmptyKasa();
        }

        num daysGross = 0;
        for (final r in live.where((r) => !r.isVoid)) {
          daysGross += r.total ?? 0;
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            Row(
              children: [
                Text('${all.length} fiş gösteriliyor',
                    style: const TextStyle(color: AppColors.brown500, fontSize: 12.5)),
                const Spacer(),
                Text('canlı pencere: ${formatPrice(daysGross)}',
                    style: const TextStyle(color: AppColors.brown600, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            SortableTable<KasaReceipt>(
              rows: all,
              initialSortColumn: 0,
              initialAscending: false,
              onRowTap: (r) => _openDetail(context, widget.repo, r),
              rowTint: (r) => r.isVoid ? AppColors.terracotta.withValues(alpha: 0.07) : null,
              columns: [
                SortColumn(
                  label: 'Saat',
                  width: 116,
                  sortKey: (r) => r.soldAt.millisecondsSinceEpoch,
                  cell: (r) => Text('${_hm(r.soldAt)}  ·  ${_dm(r.soldAt)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brown600)),
                ),
                SortColumn(
                  label: 'Fiş No',
                  width: 80,
                  numeric: true,
                  sortKey: (r) => r.receiptNo ?? 0,
                  cell: (r) => Text('${r.receiptNo ?? '-'}'),
                ),
                SortColumn(
                  label: 'Tutar',
                  width: 110,
                  numeric: true,
                  sortKey: (r) => r.total ?? 0,
                  cell: (r) => Text(formatPrice(r.total),
                      style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.brown900)),
                ),
                SortColumn(
                  label: 'Ödeme',
                  width: 84,
                  sortKey: (r) => _payLabel(r),
                  cell: (r) => Text(_payLabel(r)),
                ),
                SortColumn(
                  label: 'Ürün',
                  width: 64,
                  numeric: true,
                  sortKey: (r) => r.lineCount ?? 0,
                  cell: (r) => Text('${r.lineCount ?? '-'}'),
                ),
                SortColumn(
                  label: 'İndirim',
                  width: 92,
                  numeric: true,
                  sortKey: (r) => r.discountTotal ?? 0,
                  cell: (r) => Text(
                    (r.discountTotal ?? 0) > 0 ? formatPrice(r.discountTotal) : '-',
                    style: TextStyle(color: (r.discountTotal ?? 0) > 0 ? AppColors.mustard : AppColors.brown400),
                  ),
                ),
                SortColumn(
                  label: 'Durum',
                  flex: 1,
                  sortKey: (r) => r.isVoid ? 1 : 0,
                  cell: (r) => r.isVoid
                      ? const _Badge('İPTAL', AppColors.terracotta)
                      : const Text('—', style: TextStyle(color: AppColors.brown300)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Center(
              child: OutlinedButton.icon(
                onPressed: _loadingMore || live.isEmpty ? null : () => _loadMore(live.last.id),
                icon: _loadingMore
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.expand_more, size: 18),
                label: Text(_loadingMore ? 'Yükleniyor…' : 'Daha eski fişler'),
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _openDetail(BuildContext context, KasaRepo repo, KasaReceipt r) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ReceiptDetailSheet(repo: repo, receipt: r),
  );
}

class _ReceiptDetailSheet extends StatelessWidget {
  final KasaRepo repo;
  final KasaReceipt receipt;
  const _ReceiptDetailSheet({required this.repo, required this.receipt});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => FutureBuilder<({List<KasaReceiptLine> lines, List<KasaPayment> payments})>(
        future: repo.getReceiptDetail(receipt),
        builder: (context, snap) {
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [
              Row(
                children: [
                  Text('Fiş #${receipt.receiptNo ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
                  const SizedBox(width: 10),
                  if (receipt.isVoid) const _Badge('İPTAL', AppColors.terracotta),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_dmy(receipt.soldAt)}  ${_hm(receipt.soldAt)}'
                '${receipt.zNo != null ? '  ·  Z${receipt.zNo}' : ''}'
                '${receipt.cashierNo != null ? '  ·  Kasiyer ${receipt.cashierNo}' : ''}',
                style: const TextStyle(color: AppColors.brown500, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  _kv('Toplam', formatPrice(receipt.total)),
                  _kv('KDV', formatPrice(receipt.vatTotal)),
                  if ((receipt.discountTotal ?? 0) > 0) _kv('İndirim', formatPrice(receipt.discountTotal)),
                  if ((receipt.cashTotal ?? 0) > 0) _kv('Nakit', formatPrice(receipt.cashTotal)),
                  if ((receipt.cardTotal ?? 0) > 0) _kv('Kart', formatPrice(receipt.cardTotal)),
                ],
              ),
              if (receipt.note != null) ...[
                const SizedBox(height: 10),
                Text('Not: ${receipt.note}', style: const TextStyle(color: AppColors.brown600, fontSize: 12.5)),
              ],
              const SizedBox(height: 18),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                const Text('Satırlar', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                const SizedBox(height: 8),
                SortableTable<KasaReceiptLine>(
                  rows: snap.data!.lines,
                  initialSortColumn: 0,
                  initialAscending: true,
                  emptyText: 'Satır yok.',
                  rowTint: (l) => l.isVoidLine ? AppColors.terracotta.withValues(alpha: 0.07) : null,
                  columns: [
                    SortColumn(
                      label: '#',
                      width: 40,
                      numeric: true,
                      sortKey: (l) => l.lineNo ?? 0,
                      cell: (l) => Text('${l.lineNo ?? '-'}', style: const TextStyle(color: AppColors.brown400)),
                    ),
                    SortColumn(
                      label: 'Ürün',
                      flex: 3,
                      sortKey: (l) => (l.name ?? l.barcode ?? '').toLowerCase(),
                      cell: (l) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.name ?? l.barcode ?? '-',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  decoration: l.isVoidLine ? TextDecoration.lineThrough : null)),
                          if (l.name != null && l.barcode != null)
                            Text(l.barcode!, style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
                        ],
                      ),
                    ),
                    SortColumn(
                      label: 'Adet',
                      width: 66,
                      numeric: true,
                      sortKey: (l) => l.qty ?? 0,
                      cell: (l) => Text(_qty(l.qty)),
                    ),
                    SortColumn(
                      label: 'Birim',
                      width: 84,
                      numeric: true,
                      sortKey: (l) => l.unitPrice ?? 0,
                      cell: (l) => Text(formatPrice(l.unitPrice)),
                    ),
                    SortColumn(
                      label: 'KDV',
                      width: 52,
                      numeric: true,
                      sortKey: (l) => l.vatRate ?? 0,
                      cell: (l) => Text(l.vatRate == null ? '-' : '%${l.vatRate!.toStringAsFixed(0)}'),
                    ),
                    SortColumn(
                      label: 'Tutar',
                      width: 92,
                      numeric: true,
                      sortKey: (l) => l.lineTotal ?? 0,
                      cell: (l) => Text(formatPrice(l.lineTotal),
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.brown900)),
                    ),
                  ],
                ),
                if (snap.data!.payments.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Ödemeler', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                  const SizedBox(height: 8),
                  for (final p in snap.data!.payments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          _Badge(p.methodLabel, p.method == 'kart' ? AppColors.brown600 : AppColors.success),
                          const Spacer(),
                          Text(formatPrice(p.amount),
                              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.brown900)),
                        ],
                      ),
                    ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _kv(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(k, style: const TextStyle(fontSize: 11, color: AppColors.brown400)),
          Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.brown900)),
        ],
      );
}

// ===========================================================================
// 2. Günlük Özet
// ===========================================================================

class _DaySummarySection extends StatefulWidget {
  final KasaRepo repo;
  const _DaySummarySection({required this.repo});

  @override
  State<_DaySummarySection> createState() => _DaySummarySectionState();
}

class _DaySummarySectionState extends State<_DaySummarySection> {
  DateTime _day = DateTime.now();
  int _topRange = 0; // 0 = seçili gün, 7, 30
  late Future<KasaDaySummary> _summary;
  late Future<List<KasaProductSales>> _top;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _summary = widget.repo.getDaySummary(_day);
    _reloadTop();
  }

  void _reloadTop() {
    if (_topRange == 0) {
      _top = widget.repo.getTopProductsForDay(_day);
    } else {
      final to = DateTime.now();
      _top = widget.repo.getTopProductsRange(to.subtract(Duration(days: _topRange - 1)), to);
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 400)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _day = picked;
        _reload();
      });
    }
  }

  void _shift(int days) => setState(() {
        _day = _day.add(Duration(days: days));
        if (_day.isAfter(DateTime.now())) {
          _day = DateTime.now();
        }
        _reload();
      });

  @override
  Widget build(BuildContext context) {
    final isToday = DateUtils.isSameDay(_day, DateTime.now());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Row(
          children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            TextButton.icon(
              onPressed: _pickDay,
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(isToday ? 'Bugün · ${_dmy(_day)}' : _dmy(_day),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            IconButton(onPressed: isToday ? null : () => _shift(1), icon: const Icon(Icons.chevron_right)),
            const Spacer(),
            IconButton(onPressed: () => setState(_reload), icon: const Icon(Icons.refresh, color: AppColors.brown600)),
          ],
        ),
        const SizedBox(height: 8),
        FutureBuilder<KasaDaySummary>(
          future: _summary,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
            }
            final s = snap.data!;
            if (s.receiptCount == 0 && s.voidCount == 0) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 50),
                child: Center(child: Text('Bu gün için kasa kaydı yok.', style: TextStyle(color: AppColors.brown500))),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Metric('Ciro', formatPrice(s.gross), big: true, color: AppColors.success),
                    _Metric('Fiş', '${s.receiptCount}'),
                    _Metric('Ort. Sepet', formatPrice(s.avgBasket)),
                    _Metric('Satılan Ürün', _qty(s.itemsSold)),
                    _Metric('Nakit', formatPrice(s.cash)),
                    _Metric('Kart', formatPrice(s.card)),
                    _Metric('İndirim', formatPrice(s.discount), color: s.discount > 0 ? AppColors.mustard : null),
                    _Metric('İptal', '${s.voidCount}  (${formatPrice(s.voidValue)})',
                        color: s.voidCount > 0 ? AppColors.terracotta : null),
                  ],
                ),
                const SizedBox(height: 22),
                const Text('Saatlik Ciro', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                const SizedBox(height: 10),
                _HourlyBars(byHour: s.byHour),
              ],
            );
          },
        ),
        const SizedBox(height: 26),
        const Text('En Çok Satan Ürünler', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
        const SizedBox(height: 4),
        const Text('Ciroya göre. Sütun başlığına tıklayarak istediğiniz gibi sıralayın.',
            style: TextStyle(color: AppColors.brown500, fontSize: 12)),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final o in const [(0, 'Seçili gün'), (7, 'Son 7 gün'), (30, 'Son 30 gün')]) ...[
              ChoiceChip(
                label: Text(o.$2),
                selected: _topRange == o.$1,
                onSelected: (_) => setState(() {
                  _topRange = o.$1;
                  _reloadTop();
                }),
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                    color: _topRange == o.$1 ? Colors.white : AppColors.brown700,
                    fontWeight: FontWeight.w600,
                    fontSize: 12),
                backgroundColor: AppColors.brown100,
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<KasaProductSales>>(
          future: _top,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Center(child: CircularProgressIndicator()));
            }
            return _ProductSalesTable(rows: snap.data!);
          },
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final bool big;
  final Color? color;
  const _Metric(this.label, this.value, {this.big = false, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: big ? 210 : 150,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.brown400)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: big ? 24 : 17,
                  fontWeight: FontWeight.w800,
                  color: color ?? AppColors.brown900)),
        ],
      ),
    );
  }
}

class _HourlyBars extends StatelessWidget {
  final List<num> byHour;
  const _HourlyBars({required this.byHour});

  @override
  Widget build(BuildContext context) {
    // Only show the active trading window (first..last non-zero hour), so the
    // chart isn't 24 columns with 8 of them empty.
    var lo = 0, hi = 23;
    while (lo < 23 && byHour[lo] == 0) {
      lo++;
    }
    while (hi > lo && byHour[hi] == 0) {
      hi--;
    }
    final maxV = byHour.fold<num>(0, (m, v) => v > m ? v : m);
    if (maxV == 0) {
      return const Text('Bu gün için satış yok.', style: TextStyle(color: AppColors.brown400, fontSize: 12));
    }
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var h = lo; h <= hi; h++)
            Expanded(
              child: Tooltip(
                message: '${h.toString().padLeft(2, '0')}:00 — ${formatPrice(byHour[h])}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        byHour[h] == 0 ? '' : _compact(byHour[h]),
                        style: const TextStyle(fontSize: 8.5, color: AppColors.brown400),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: (110 * (byHour[h] / maxV)).clamp(byHour[h] > 0 ? 3.0 : 0.0, 110.0),
                        decoration: BoxDecoration(
                          color: AppColors.terracotta.withValues(alpha: 0.85),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(h.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 9, color: AppColors.brown500)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _compact(num v) {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k';
    return v.toStringAsFixed(0);
  }
}

/// Shared sortable table for "products with sales" rows (top products today
/// and over a range). Row tap opens the product peek sheet.
class _ProductSalesTable extends StatelessWidget {
  final List<KasaProductSales> rows;
  const _ProductSalesTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return SortableTable<KasaProductSales>(
      rows: rows,
      initialSortColumn: 2, // revenue
      initialAscending: false,
      emptyText: 'Satış kaydı yok.',
      onRowTap: (s) => _peekProduct(context, s.barcode),
      columns: [
        SortColumn(
          label: 'Ürün',
          flex: 3,
          sortKey: (s) => (s.product?.stockname ?? s.barcode).toLowerCase(),
          cell: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.product?.stockname ?? s.barcode,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(s.barcode, style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
            ],
          ),
        ),
        SortColumn(
          label: 'Adet',
          width: 74,
          numeric: true,
          sortKey: (s) => s.qty,
          cell: (s) => Text(_qty(s.qty)),
        ),
        SortColumn(
          label: 'Ciro',
          width: 104,
          numeric: true,
          sortKey: (s) => s.revenue,
          cell: (s) => Text(formatPrice(s.revenue),
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.brown900)),
        ),
        SortColumn(
          label: 'Fiş',
          width: 56,
          numeric: true,
          sortKey: (s) => s.lineCount,
          cell: (s) => Text('${s.lineCount}'),
        ),
        SortColumn(
          label: 'Güncel Fiyat',
          width: 100,
          numeric: true,
          sortKey: (s) => s.product?.price ?? -1,
          cell: (s) => Text(s.product?.price == null ? '-' : formatPrice(s.product!.price),
              style: const TextStyle(color: AppColors.brown500)),
        ),
      ],
    );
  }
}

// ===========================================================================
// 3. İptaller
// ===========================================================================

class _VoidsSection extends StatefulWidget {
  final KasaRepo repo;
  const _VoidsSection({required this.repo});

  @override
  State<_VoidsSection> createState() => _VoidsSectionState();
}

class _VoidsSectionState extends State<_VoidsSection> {
  int _days = 7;
  late Future<List<KasaReceipt>> _future = widget.repo.getVoidReceipts(daysBack: _days);

  void _setDays(int d) => setState(() {
        _days = d;
        _future = widget.repo.getVoidReceipts(daysBack: d);
      });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Row(
          children: [
            const Text('Son', style: TextStyle(color: AppColors.brown500, fontSize: 12.5)),
            const SizedBox(width: 8),
            for (final d in const [7, 30, 90]) ...[
              ChoiceChip(
                label: Text('$d gün'),
                selected: _days == d,
                onSelected: (_) => _setDays(d),
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                    color: _days == d ? Colors.white : AppColors.brown700, fontWeight: FontWeight.w600, fontSize: 12),
                backgroundColor: AppColors.brown100,
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 14),
        FutureBuilder<List<KasaReceipt>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data!;
            num total = 0;
            for (final r in rows) {
              total += r.total ?? 0;
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${rows.length} iptal fişi  ·  toplam ${formatPrice(total)}',
                    style: const TextStyle(color: AppColors.brown600, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                SortableTable<KasaReceipt>(
                  rows: rows,
                  initialSortColumn: 0,
                  initialAscending: false,
                  emptyText: 'Bu dönemde iptal fişi yok.',
                  onRowTap: (r) => _openDetail(context, widget.repo, r),
                  columns: [
                    SortColumn(
                      label: 'Tarih',
                      width: 150,
                      sortKey: (r) => r.soldAt.millisecondsSinceEpoch,
                      cell: (r) => Text('${_dmy(r.soldAt)}  ${_hm(r.soldAt)}',
                          style: const TextStyle(fontSize: 12, color: AppColors.brown600)),
                    ),
                    SortColumn(
                      label: 'Fiş No',
                      width: 80,
                      numeric: true,
                      sortKey: (r) => r.receiptNo ?? 0,
                      cell: (r) => Text('${r.receiptNo ?? '-'}'),
                    ),
                    SortColumn(
                      label: 'Tutar',
                      width: 110,
                      numeric: true,
                      sortKey: (r) => r.total ?? 0,
                      cell: (r) => Text(formatPrice(r.total),
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.terracotta)),
                    ),
                    SortColumn(
                      label: 'Ürün',
                      width: 64,
                      numeric: true,
                      sortKey: (r) => r.lineCount ?? 0,
                      cell: (r) => Text('${r.lineCount ?? '-'}'),
                    ),
                    SortColumn(
                      label: 'Kasiyer',
                      width: 78,
                      numeric: true,
                      sortKey: (r) => r.cashierNo ?? 0,
                      cell: (r) => Text(r.cashierNo == null ? '-' : 'Kasiyer ${r.cashierNo}',
                          style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
                    ),
                    SortColumn(
                      label: 'Not',
                      flex: 2,
                      sortKey: (r) => (r.note ?? '').toLowerCase(),
                      cell: (r) => Text(r.note ?? '-',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ===========================================================================
// 4. Fiyat Uyuşmazlığı
// ===========================================================================

class _MismatchSection extends StatefulWidget {
  final KasaRepo repo;
  const _MismatchSection({required this.repo});

  @override
  State<_MismatchSection> createState() => _MismatchSectionState();
}

class _MismatchSectionState extends State<_MismatchSection> {
  bool _includeResolved = false;
  Future<List<KasaPriceMismatch>>? _resolvedFuture;

  void _loadResolved() {
    _resolvedFuture = widget.repo.getMismatches(includeResolved: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        const Text(
          'Kasada işlenen fiyat ile kataloğdaki güncel fiyat farklı olduğunda burada listelenir. '
          'Son 2 günün satışları kontrol edilir — yani "kasa eski/yanlış fiyatla satıyor" uyarısıdır. '
          'Uygulamadan yapılan fiyat değişiklikleri kasaya saniyeler içinde gittiği için burada kalıcı görünmez.',
          style: TextStyle(color: AppColors.brown500, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilterChip(
              label: const Text('Çözülenleri de göster'),
              selected: _includeResolved,
              onSelected: (v) => setState(() {
                _includeResolved = v;
                if (v) _loadResolved();
              }),
              selectedColor: AppColors.brown200,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_includeResolved)
          FutureBuilder<List<KasaPriceMismatch>>(
            future: _resolvedFuture,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()));
              }
              return _mismatchTable(snap.data!);
            },
          )
        else
          StreamBuilder<List<KasaPriceMismatch>>(
            stream: widget.repo.watchOpenMismatches(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()));
              }
              return _mismatchTable(snap.data!);
            },
          ),
      ],
    );
  }

  Widget _mismatchTable(List<KasaPriceMismatch> rows) {
    return SortableTable<KasaPriceMismatch>(
      rows: rows,
      initialSortColumn: 0,
      initialAscending: false,
      emptyText: 'Açık fiyat uyuşmazlığı yok. 👍',
      onRowTap: (m) => _peekProduct(context, m.barcode),
      rowTint: (m) => m.resolved ? AppColors.brown100.withValues(alpha: 0.4) : null,
      columns: [
        SortColumn(
          label: 'Zaman',
          width: 132,
          sortKey: (m) => m.soldAt.millisecondsSinceEpoch,
          cell: (m) => Text('${_dm(m.soldAt)}  ${_hm(m.soldAt)}',
              style: const TextStyle(fontSize: 12, color: AppColors.brown600)),
        ),
        SortColumn(
          label: 'Ürün',
          flex: 3,
          sortKey: (m) => (m.name ?? m.barcode).toLowerCase(),
          cell: (m) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.name ?? m.barcode, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(m.barcode, style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
            ],
          ),
        ),
        SortColumn(
          label: 'Kasada',
          width: 92,
          numeric: true,
          sortKey: (m) => m.tillPrice,
          cell: (m) => Text(formatPrice(m.tillPrice), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        SortColumn(
          label: 'Katalog',
          width: 92,
          numeric: true,
          sortKey: (m) => m.catalogPrice,
          cell: (m) => Text(formatPrice(m.catalogPrice), style: const TextStyle(color: AppColors.brown500)),
        ),
        SortColumn(
          label: 'Fark',
          width: 92,
          numeric: true,
          sortKey: (m) => m.diff,
          cell: (m) => Text(
            '${m.diff > 0 ? '+' : ''}${formatPrice(m.diff)}',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                color: m.tillCheaper ? AppColors.terracotta : AppColors.mustard),
          ),
        ),
        SortColumn(
          label: 'Fiş',
          width: 56,
          numeric: true,
          sortKey: (m) => m.receiptNo ?? 0,
          cell: (m) => Text('${m.receiptNo ?? '-'}', style: const TextStyle(color: AppColors.brown400)),
        ),
        SortColumn(
          label: '',
          width: 116,
          sortKey: (m) => m.resolved ? 1 : 0,
          cell: (m) => Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                await widget.repo.setMismatchResolved(m.id, !m.resolved);
                if (mounted && _includeResolved) setState(_loadResolved);
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: m.resolved ? AppColors.brown500 : AppColors.success,
              ),
              child: Text(m.resolved ? 'Geri al' : 'Çözüldü', style: const TextStyle(fontSize: 12)),
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// 5. Z Raporları
// ===========================================================================

class _ZReportsSection extends StatefulWidget {
  final KasaRepo repo;
  const _ZReportsSection({required this.repo});

  @override
  State<_ZReportsSection> createState() => _ZReportsSectionState();
}

class _ZReportsSectionState extends State<_ZReportsSection> {
  late final Future<List<KasaZReport>> _future = widget.repo.getZReports();

  @override
  Widget build(BuildContext context) {
    return _pad(
      FutureBuilder<List<KasaZReport>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
          }
          final rows = snap.data!;
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              Text('Son ${rows.length} Z raporu. Bir satıra dokunarak rapor metnini görün.',
                  style: const TextStyle(color: AppColors.brown500, fontSize: 12.5)),
              const SizedBox(height: 12),
              SortableTable<KasaZReport>(
                rows: rows,
                initialSortColumn: 1, // Tarih (z_no can reset, see repo)
                initialAscending: false,
                emptyText: 'Z raporu yok.',
                onRowTap: (z) => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => _ZReportSheet(report: z),
                ),
                columns: [
                  SortColumn(
                    label: 'Z No',
                    width: 90,
                    numeric: true,
                    sortKey: (z) => z.zNo ?? 0,
                    cell: (z) => Text('Z${z.zNo ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  SortColumn(
                    label: 'Tarih',
                    flex: 2,
                    sortKey: (z) => z.zDate?.millisecondsSinceEpoch ?? 0,
                    cell: (z) => Text(z.zDate == null ? '-' : '${_dmy(z.zDate!)}  ${_hm(z.zDate!)}',
                        style: const TextStyle(fontSize: 12.5, color: AppColors.brown600)),
                  ),
                  SortColumn(
                    label: 'Ciro',
                    width: 130,
                    numeric: true,
                    sortKey: (z) => z.turnover ?? 0,
                    cell: (z) => Text(formatPrice(z.turnover),
                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.success)),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ZReportSheet extends StatelessWidget {
  final KasaZReport report;
  const _ZReportSheet({required this.report});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          Text('Z${report.zNo ?? '-'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
          const SizedBox(height: 2),
          Text(
            '${report.zDate == null ? '' : '${_dmy(report.zDate!)}  ${_hm(report.zDate!)}   ·   '}'
            'Ciro ${formatPrice(report.turnover)}',
            style: const TextStyle(color: AppColors.brown500, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          if (report.info == null)
            const Text('Bu rapor için ayrıntılı metin yok.', style: TextStyle(color: AppColors.brown400))
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cream,
                borderRadius: BorderRadius.circular(AppRadius.box),
                border: Border.all(color: AppColors.creamBorder),
              ),
              child: SelectableText(report.info!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppColors.brown800, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// 6. Ölü Stok
// ===========================================================================

class _DeadStockSection extends StatefulWidget {
  final KasaRepo repo;
  const _DeadStockSection({required this.repo});

  @override
  State<_DeadStockSection> createState() => _DeadStockSectionState();
}

class _DeadStockSectionState extends State<_DeadStockSection> {
  int _days = 30;
  bool _requireHistory = true;
  late Future<List<KasaDeadStockItem>> _future = _load();

  Future<List<KasaDeadStockItem>> _load() =>
      widget.repo.getDeadStock(days: _days, requireHistory: _requireHistory);

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        const Text(
          'Son X gün içinde kasada hiç satılmayan katalog ürünleri. '
          '"Geçmişte satılmış" seçiliyken yalnızca eskiden satan ama artık durmuş ürünler gösterilir.',
          style: TextStyle(color: AppColors.brown500, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Satış yok:', style: TextStyle(color: AppColors.brown500, fontSize: 12.5)),
            const SizedBox(width: 8),
            for (final d in const [14, 30, 60, 90]) ...[
              ChoiceChip(
                label: Text('$d g'),
                selected: _days == d,
                onSelected: (_) {
                  _days = d;
                  _reload();
                },
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                    color: _days == d ? Colors.white : AppColors.brown700, fontWeight: FontWeight.w600, fontSize: 12),
                backgroundColor: AppColors.brown100,
              ),
              const SizedBox(width: 6),
            ],
            const SizedBox(width: 10),
            FilterChip(
              label: const Text('Geçmişte satılmış'),
              selected: _requireHistory,
              onSelected: (v) {
                _requireHistory = v;
                _reload();
              },
              selectedColor: AppColors.brown200,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FutureBuilder<List<KasaDeadStockItem>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${rows.length} ürün',
                    style: const TextStyle(color: AppColors.brown600, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                SortableTable<KasaDeadStockItem>(
                  rows: rows,
                  initialSortColumn: 4, // last sold
                  initialAscending: false,
                  emptyText: 'Bu ölçüte uyan ürün yok.',
                  onRowTap: (d) => _peekProduct(context, d.barcode),
                  columns: [
                    SortColumn(
                      label: 'Ürün',
                      flex: 3,
                      sortKey: (d) => d.stockname.toLowerCase(),
                      cell: (d) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d.stockname, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(d.barcode, style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
                        ],
                      ),
                    ),
                    SortColumn(
                      label: 'Fiyat',
                      width: 92,
                      numeric: true,
                      sortKey: (d) => d.price ?? 0,
                      cell: (d) => Text(formatPrice(d.price)),
                    ),
                    SortColumn(
                      label: 'Reyon',
                      width: 96,
                      sortKey: (d) => (d.depno ?? '').toLowerCase(),
                      cell: (d) => Text(d.depno ?? '-', style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
                    ),
                    SortColumn(
                      label: 'Dönem Adedi',
                      width: 104,
                      numeric: true,
                      sortKey: (d) => d.qtyWindow,
                      cell: (d) => Text(_qty(d.qtyWindow), style: const TextStyle(color: AppColors.brown500)),
                    ),
                    SortColumn(
                      label: 'Son Satış',
                      width: 128,
                      numeric: true,
                      sortKey: (d) => d.lastSoldAt?.millisecondsSinceEpoch ?? 0,
                      cell: (d) => Text(
                        d.lastSoldAt == null
                            ? 'hiç'
                            : '${_dmy(d.lastSoldAt!)}  (${d.daysSince} g)',
                        style: const TextStyle(fontSize: 12, color: AppColors.brown600),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ===========================================================================

class _EmptyKasa extends StatelessWidget {
  const _EmptyKasa();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.point_of_sale_outlined, size: 40, color: AppColors.brown300),
              SizedBox(height: 12),
              Text('Henüz kasa verisi yok.',
                  style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600)),
              SizedBox(height: 6),
              Text('Kasa senkron servisi ilk verileri aktardığında burada görünecek.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.brown400, fontSize: 12.5)),
            ],
          ),
        ),
      );
}
