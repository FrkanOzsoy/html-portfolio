import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_settings.dart';
import '../format.dart';
import '../kasa_repo.dart';
import '../models.dart';
import '../platform_util.dart';
import '../theme.dart';
import '../widgets/product_peek_sheet.dart';
import '../widgets/product_sales_table.dart';
import '../widgets/sortable_table.dart';
import 'kasap_screen.dart';

// ===========================================================================
// Mobile: İstatistik is behind a one-time PIN. Once entered it stays unlocked
// on that device (like staying logged in).
// ===========================================================================

const _kIstatistikPin = '159951';
const _kIstatistikUnlockedKey = 'istatistik_unlocked';

class MobileIstatistikGate extends StatefulWidget {
  const MobileIstatistikGate({super.key});

  @override
  State<MobileIstatistikGate> createState() => _MobileIstatistikGateState();
}

class _MobileIstatistikGateState extends State<MobileIstatistikGate> {
  bool? _unlocked;
  final _controller = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _unlocked = p.getBool(_kIstatistikUnlockedKey) ?? false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_controller.text.trim() == _kIstatistikPin) {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kIstatistikUnlockedKey, true);
      if (mounted) setState(() => _unlocked = true);
    } else {
      setState(() => _error = 'Şifre yanlış.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unlocked!) return const IstatistikScreen();

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40, color: AppColors.brown400),
              const SizedBox(height: 12),
              const Text('İstatistik Şifresi',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
              const SizedBox(height: 20),
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, letterSpacing: 6),
                decoration: InputDecoration(
                  hintText: '••••••',
                  errorText: _error,
                  isDense: true,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(onPressed: _submit, child: const Text('Aç')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "İstatistik" tab -- a read-only window onto the register's
/// live sales, mirrored from INTER_BOS by the till-PC daemon (see
/// lib/kasa_repo.dart). Six sections, each with fully sortable tables:
///   Son İşlemler · Günlük Özet · İptaller · Fiyat Uyuşmazlığı ·
///   Z Raporları · Ürün Satışları
/// This is always the "Genel" destination now. Kasap/Manav are separate
/// destinations everywhere -- desktop's own top-level sections
/// (home_shell.dart's _idKasap/_idManav, dispatching to ScopedStatsBody),
/// and on mobile a choice Furkan/Ahmet make in a popup before ever reaching
/// here (see home_shell.dart's _showIstatistikChoice) rather than tabs
/// bolted onto this screen -- they used to be, but that made "İstatistik"
/// an 8-tab wall for exactly two staff members instead of three separate,
/// focused screens.
class IstatistikScreen extends StatefulWidget {
  const IstatistikScreen({super.key});

  @override
  State<IstatistikScreen> createState() => _IstatistikScreenState();
}

class _IstatistikScreenState extends State<IstatistikScreen> with SingleTickerProviderStateMixin {
  final _repo = KasaRepo();
  late final TabController _tab;

  int _openMismatches = 0;
  StreamSubscription? _mismatchSub;
  StreamSubscription? _notesSub;
  Map<String, KasaReceiptNote> _notes = const {};
  DateTime? _lastMirroredAt;
  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 6, vsync: this);
    _mismatchSub = _repo.watchOpenMismatches().listen((rows) {
      if (mounted) setState(() => _openMismatches = rows.length);
    });
    _notesSub = _repo.watchReceiptNotes().listen((map) {
      if (mounted) setState(() => _notes = map);
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
    _notesSub?.cancel();
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
            child: Column(
              children: [
                Row(
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
                          const Tab(text: 'Ürün Satışları'),
                        ],
                      ),
                    ),
                    if (isDesktopPlatform) ...[
                      _FreshnessChip(at: _lastMirroredAt),
                      const SizedBox(width: 12),
                    ],
                  ],
                ),
                if (!isDesktopPlatform)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Align(
                    alignment: Alignment.centerRight,
                    child: _FreshnessChip(at: _lastMirroredAt),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _ReceiptsSection(repo: _repo, notes: _notes),
                _DaySummarySection(repo: _repo),
                _VoidsSection(repo: _repo, notes: _notes),
                _MismatchSection(repo: _repo),
                _ZReportsSection(repo: _repo),
                _UrunSatislariSection(repo: _repo),
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

/// Payment summary for a receipt row: "Nakit" / "Kart · Visa" / "Karışık".
class _PayChip extends StatelessWidget {
  final KasaReceipt receipt;
  const _PayChip(this.receipt);

  @override
  Widget build(BuildContext context) {
    final cash = receipt.cashTotal ?? 0;
    final card = receipt.cardTotal ?? 0;
    final mixed = cash > 0 && card > 0;
    final isCard = card > 0 && !mixed;
    final color = mixed ? AppColors.mustard : (isCard ? AppColors.brown600 : AppColors.success);
    if (cash == 0 && card == 0) return const Text('-', style: TextStyle(color: AppColors.brown300));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isCard ? Icons.credit_card : (mixed ? Icons.account_balance_wallet_outlined : Icons.payments_outlined),
            size: 13, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(receipt.paymentLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
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

// ---- receipt notes (staff, bound to belge_id -- shared by Son İşlemler,
// İptaller and the detail sheet) -------------------------------------------

/// A sortable-table cell that shows a receipt's staff note (or the till's own
/// `Notlar` in muted text as a fallback) and a "not ekle" affordance, and
/// opens the editor on tap.
class _NoteCell extends StatelessWidget {
  final KasaRepo repo;
  final KasaReceipt receipt;
  final KasaReceiptNote? note;
  const _NoteCell({required this.repo, required this.receipt, required this.note});

  @override
  Widget build(BuildContext context) {
    final staff = note?.note;
    return InkWell(
      onTap: () => editReceiptNote(context, repo, receipt, note),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: staff != null
            ? Row(
                children: [
                  const Icon(Icons.sticky_note_2, size: 13, color: AppColors.mustard),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(staff,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppColors.brown800)),
                  ),
                ],
              )
            : receipt.note != null
                ? Text('kasa: ${receipt.note}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.brown400, fontStyle: FontStyle.italic))
                : const Row(
                    children: [
                      Icon(Icons.add, size: 12, color: AppColors.brown300),
                      SizedBox(width: 3),
                      Text('not', style: TextStyle(fontSize: 11.5, color: AppColors.brown300)),
                    ],
                  ),
      ),
    );
  }
}

SortColumn<KasaReceipt> _noteColumn(KasaRepo repo, Map<String, KasaReceiptNote> notes) => SortColumn(
      label: 'Notlar',
      flex: 3,
      // sort: receipts that have a staff note first
      sortKey: (r) => notes.containsKey(r.belgeId) ? '0${notes[r.belgeId]!.note.toLowerCase()}' : '1',
      cell: (r) => _NoteCell(repo: repo, receipt: r, note: notes[r.belgeId]),
    );

/// The one note editor -- used from every place a Fiş is shown.
Future<void> editReceiptNote(
  BuildContext context,
  KasaRepo repo,
  KasaReceipt receipt,
  KasaReceiptNote? current,
) async {
  final controller = TextEditingController(text: current?.note ?? '');
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Fiş #${receipt.receiptNo ?? '-'} — Not'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_dmy(receipt.soldAt)} ${_hm(receipt.soldAt)} · ${formatPrice(receipt.total)}'
              '${receipt.isVoid ? '  ·  İPTAL' : ''}',
              style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(hintText: 'Bu fiş hakkında not…', isDense: true),
          ),
          if (current?.updatedBy != null) ...[
            const SizedBox(height: 6),
            Text('son düzenleyen: ${current!.updatedBy} · ${_dm(current.updatedAt)} ${_hm(current.updatedAt)}',
                style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
          ],
        ],
      ),
      actions: [
        if (current != null)
          TextButton(
            onPressed: () async {
              await repo.setReceiptNote(receipt.belgeId, '');
              if (context.mounted) Navigator.pop(context, true);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.terracotta),
            child: const Text('Sil'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
        ElevatedButton(
          onPressed: () async {
            await repo.setReceiptNote(receipt.belgeId, controller.text);
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Kaydet'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not kaydedildi.')));
  }
}

// ===========================================================================
// 1. Son İşlemler
// ===========================================================================

class _ReceiptsSection extends StatefulWidget {
  final KasaRepo repo;
  final Map<String, KasaReceiptNote> notes;
  const _ReceiptsSection({required this.repo, required this.notes});

  @override
  State<_ReceiptsSection> createState() => _ReceiptsSectionState();
}

class _ReceiptsSectionState extends State<_ReceiptsSection> {
  // Cached so a parent rebuild (e.g. a note change) doesn't recreate the
  // stream and flash the spinner.
  late final Stream<List<KasaReceipt>> _stream = widget.repo.watchRecentReceipts();
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
      stream: _stream,
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
                  width: 150,
                  sortKey: (r) => r.paymentLabel,
                  cell: (r) => _PayChip(r),
                ),
                SortColumn(
                  label: 'Ürün',
                  width: 64,
                  numeric: true,
                  sortKey: (r) => r.lineCount ?? 0,
                  cell: (r) => Text('${r.lineCount ?? '-'}'),
                ),
                _noteColumn(widget.repo, widget.notes),
                SortColumn(
                  label: 'Durum',
                  width: 78,
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

class _ReceiptDetailSheet extends StatefulWidget {
  final KasaRepo repo;
  final KasaReceipt receipt;
  const _ReceiptDetailSheet({required this.repo, required this.receipt});

  @override
  State<_ReceiptDetailSheet> createState() => _ReceiptDetailSheetState();
}

class _ReceiptDetailSheetState extends State<_ReceiptDetailSheet> {
  // Cached so dragging the sheet doesn't re-run the fetch / re-subscribe.
  late final Future<({List<KasaReceiptLine> lines, List<KasaPayment> payments})> _detail =
      widget.repo.getReceiptDetail(widget.receipt);
  late final Stream<Map<String, KasaReceiptNote>> _notes = widget.repo.watchReceiptNotes();

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final receipt = widget.receipt;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => FutureBuilder<({List<KasaReceiptLine> lines, List<KasaPayment> payments})>(
        future: _detail,
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
                Text('Kasa notu: ${receipt.note}', style: const TextStyle(color: AppColors.brown500, fontSize: 12, fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: 12),
              StreamBuilder<Map<String, KasaReceiptNote>>(
                stream: _notes,
                builder: (context, ns) {
                  final note = ns.data?[receipt.belgeId];
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: note != null ? AppColors.mustard.withValues(alpha: 0.08) : AppColors.cream,
                      borderRadius: BorderRadius.circular(AppRadius.box),
                      border: Border.all(color: note != null ? AppColors.mustard.withValues(alpha: 0.4) : AppColors.creamBorder),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.sticky_note_2_outlined, size: 16, color: AppColors.mustard),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(note?.note ?? 'Bu fiş için not yok.',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: note != null ? AppColors.brown900 : AppColors.brown400)),
                              if (note?.updatedBy != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text('${note!.updatedBy} · ${_dm(note.updatedAt)} ${_hm(note.updatedAt)}',
                                      style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
                                ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => editReceiptNote(context, repo, receipt, note),
                          icon: Icon(note != null ? Icons.edit : Icons.add, size: 15),
                          label: Text(note != null ? 'Düzenle' : 'Not Ekle'),
                          style: TextButton.styleFrom(foregroundColor: AppColors.mustard),
                        ),
                      ],
                    ),
                  );
                },
              ),
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
                  for (final p in snap.data!.payments) _PaymentRow(p),
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

/// One payment line in the receipt detail sheet -- for a card payment, shows
/// the masked PAN, scheme, installments, auth code, terminal + batch.
class _PaymentRow extends StatelessWidget {
  final KasaPayment p;
  const _PaymentRow(this.p);

  @override
  Widget build(BuildContext context) {
    final bits = <String>[
      if (p.maskedPan != null) p.maskedPan!,
      if ((p.installments ?? 0) > 1) '${p.installments} taksit',
      if (p.authCode != null) 'onay ${p.authCode}',
      if (p.terminalNo != null) 'term. ${p.terminalNo}',
      if (p.batchNo != null) 'batch ${p.batchNo}',
    ];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge(p.methodLabel, p.isCard ? AppColors.brown600 : AppColors.success),
              const Spacer(),
              Text(formatPrice(p.amount),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.brown900)),
            ],
          ),
          if (bits.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(bits.join('  ·  '),
                  style: const TextStyle(fontSize: 11, color: AppColors.brown500, fontFeatures: [FontFeature.tabularFigures()])),
            ),
        ],
      ),
    );
  }
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
                if (s.cardByBrand.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  const Text('Kart Dağılımı', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                  const SizedBox(height: 4),
                  Text('Toplam kart: ${formatPrice(s.card)}',
                      style: const TextStyle(color: AppColors.brown500, fontSize: 12)),
                  const SizedBox(height: 10),
                  _CardBrandBreakdown(cardByBrand: s.cardByBrand, cardTotal: s.card),
                ],
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

/// Horizontal split-bar of card turnover by scheme (Visa / Mastercard / Troy…).
class _CardBrandBreakdown extends StatelessWidget {
  final Map<String, num> cardByBrand;
  final num cardTotal;
  const _CardBrandBreakdown({required this.cardByBrand, required this.cardTotal});

  static const _brandColor = {
    'Visa': Color(0xFF4A6FA5),
    'Mastercard': Color(0xFFB5502F),
    'Troy': Color(0xFF3E8E9E),
    'Amex': Color(0xFF6B4E8E),
    'Diners': Color(0xFF9E6B8E),
    'UnionPay': Color(0xFF7B6BA5),
    'Karışık': AppColors.mustard,
    'Kart': AppColors.brown400,
  };

  @override
  Widget build(BuildContext context) {
    final entries = cardByBrand.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = cardTotal == 0 ? 1 : cardTotal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              for (final e in entries)
                Expanded(
                  flex: ((e.value / total) * 1000).round().clamp(1, 1000),
                  child: Container(height: 14, color: _brandColor[e.key] ?? AppColors.brown300),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (final e in entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(
                      color: _brandColor[e.key] ?? AppColors.brown300, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 6),
                  Text('${e.key}  ',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.brown800)),
                  Text('${formatPrice(e.value)} · %${(e.value / total * 100).toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _HourlyBars extends StatelessWidget {
  final List<num> byHour;
  final double height;
  const _HourlyBars({required this.byHour, this.height = 150});

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
    final barMax = height - 40;
    return SizedBox(
      height: height,
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
                        height: (barMax * (byHour[h] / maxV)).clamp(byHour[h] > 0 ? 3.0 : 0.0, barMax),
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

/// Same visual shape as [_HourlyBars] but one bar per day over a date
/// range instead of one per hour of a single day -- Kasap/Manav's "Özet"
/// is range-scoped, not single-day, so a daily chart is the meaningful
/// equivalent. A range can span many days (e.g. "Son 90 gün"), so this
/// scrolls horizontally with a fixed bar width instead of stretching to
/// fill, unlike the always-24-slot hourly chart.
class _DailyBars extends StatelessWidget {
  final List<KasaDailyTrendPoint> points; // assumed sorted ascending by date
  final double height;
  const _DailyBars({required this.points, this.height = 150});

  @override
  Widget build(BuildContext context) {
    final maxV = points.fold<num>(0, (m, p) => p.revenue > m ? p.revenue : m);
    if (points.isEmpty || maxV == 0) {
      return const Text('Bu dönem için satış yok.', style: TextStyle(color: AppColors.brown400, fontSize: 12));
    }
    final barMax = height - 40;
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final p in points)
              SizedBox(
                width: 38,
                child: Tooltip(
                  message: '${_dmy(p.date)} — ${formatPrice(p.revenue)}',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          p.revenue == 0 ? '' : _HourlyBars._compact(p.revenue),
                          style: const TextStyle(fontSize: 8.5, color: AppColors.brown400),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: (barMax * (p.revenue / maxV)).clamp(p.revenue > 0 ? 3.0 : 0.0, barMax),
                          decoration: BoxDecoration(
                            color: AppColors.terracotta.withValues(alpha: 0.85),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(p.date.day.toString().padLeft(2, '0'),
                            style: const TextStyle(fontSize: 9, color: AppColors.brown500)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Same visual shape as [_CardBrandBreakdown] (proportional stacked bar +
/// legend) but for revenue share by product within a scoped set -- Kasap/
/// Manav's "pie chart" of which products actually drive their category's
/// revenue. Unlike payment-method mix (inherently receipt-level, see
/// _ScopedSummarySection), this is exact -- no cross-attribution ambiguity.
class _ProductRevenueBreakdown extends StatelessWidget {
  final List<KasaProductSalesReport> rows;
  const _ProductRevenueBreakdown({required this.rows});

  static const _maxSlices = 8;
  static const _sliceColors = [
    AppColors.terracotta,
    Color(0xFF4A6FA5),
    Color(0xFF3E8E9E),
    AppColors.mustard,
    Color(0xFF6B4E8E),
    Color(0xFFB5502F),
    Color(0xFF7B6BA5),
    AppColors.brown400,
  ];

  @override
  Widget build(BuildContext context) {
    final sold = rows.where((r) => r.revenue > 0).toList()..sort((a, b) => b.revenue.compareTo(a.revenue));
    if (sold.isEmpty) {
      return const Text('Bu dönem için satış yok.', style: TextStyle(color: AppColors.brown400, fontSize: 12));
    }
    final top = sold.take(_maxSlices).toList();
    final restRevenue = sold.skip(_maxSlices).fold<num>(0, (m, r) => m + r.revenue);
    final total = sold.fold<num>(0, (m, r) => m + r.revenue);
    final slices = [
      for (final r in top) (label: r.stockname, value: r.revenue),
      if (restRevenue > 0) (label: 'Diğer', value: restRevenue),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              for (var i = 0; i < slices.length; i++)
                Expanded(
                  flex: ((slices[i].value / total) * 1000).round().clamp(1, 1000),
                  child: Container(height: 14, color: _sliceColors[i % _sliceColors.length]),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (var i = 0; i < slices.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: _sliceColors[i % _sliceColors.length], borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 6),
                  Text('${slices[i].label}  ',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.brown800)),
                  Text('${formatPrice(slices[i].value)} · %${(slices[i].value / total * 100).toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brown500)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Receipts that touched a scoped barcode set (Kasap/Manav's "Son
/// İşlemler" and "İptaller" tabs) -- unlike the real Son İşlemler, this is
/// a one-shot fetch (kasa_receipts_for_barcodes can't be a realtime
/// `.stream()`) with a manual refresh, not a live feed. [voidOnly] picks
/// which of the two tabs this renders: false shows every touching receipt
/// (with a Durum/Ödeme column, matching Son İşlemler's shape), true shows
/// only voided ones (matching İptaller's simpler column set).
class _ScopedReceiptsSection extends StatefulWidget {
  final KasaRepo repo;
  final List<String> barcodes;
  final Map<String, KasaReceiptNote> notes;
  final bool voidOnly;
  const _ScopedReceiptsSection({
    required this.repo,
    required this.barcodes,
    required this.notes,
    required this.voidOnly,
  });

  @override
  State<_ScopedReceiptsSection> createState() => _ScopedReceiptsSectionState();
}

class _ScopedReceiptsSectionState extends State<_ScopedReceiptsSection> {
  // Row cap for the table itself -- the header line's fiş/toplam counts
  // still come from getReceiptsSummaryForBarcodes (exact, never capped), so
  // a range with more than this many receipts is visibly flagged as
  // truncated rather than silently under-reported. 200 -> 100: this table
  // is for spot-checking specific receipts, not a full export -- a tighter
  // cap keeps a wide Özel range from paging in more than it needs to.
  static const _rowLimit = 100;

  int? _days = 7;
  DateTimeRange? _customRange;
  late Future<({List<KasaReceipt> rows, ScopedReceiptsSummary summary})> _future = _load();

  Future<({List<KasaReceipt> rows, ScopedReceiptsSummary summary})> _load() async {
    final DateTime from;
    final DateTime to;
    if (_customRange != null) {
      from = _customRange!.start;
      // showDateRangePicker returns day-precision dates -- push the upper
      // bound to the start of the next day so the last selected day's own
      // receipts aren't excluded by an exclusive/timestamp comparison.
      to = _customRange!.end.add(const Duration(days: 1));
    } else {
      from = DateTime.now().subtract(Duration(days: _days!));
      to = DateTime.now();
    }
    // rows: capped display list (a table doesn't need thousands of rows).
    // summary: exact, unlimited count/total for the header line above it --
    // deliberately NOT derived from rows.length/summed rows, which would
    // silently understate on any range with more matching receipts than
    // the cap.
    final rows = await widget.repo.getReceiptsForBarcodes(
      barcodes: widget.barcodes,
      from: from,
      to: to,
      voidOnly: widget.voidOnly,
      limit: _rowLimit,
    );
    final summary = await widget.repo.getReceiptsSummaryForBarcodes(barcodes: widget.barcodes, from: from, to: to);
    return (rows: rows, summary: summary);
  }

  void _setDays(int d) => setState(() {
        _days = d;
        _customRange = null;
        _future = _load();
      });

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final initial = _customRange ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now);
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
    if (picked == null) return;
    setState(() {
      _days = null;
      _customRange = picked;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Son', style: TextStyle(color: AppColors.brown500, fontSize: 12.5)),
            for (final d in const [7, 30, 90])
              ChoiceChip(
                label: Text('$d gün'),
                selected: _days == d,
                onSelected: (_) => _setDays(d),
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                    color: _days == d ? Colors.white : AppColors.brown700, fontWeight: FontWeight.w600, fontSize: 12),
                backgroundColor: AppColors.brown100,
              ),
            ActionChip(
              label: Text(_customRange == null ? 'Özel' : '${_dm(_customRange!.start)} - ${_dm(_customRange!.end)}'),
              onPressed: _pickCustomRange,
              backgroundColor: _customRange != null ? AppColors.terracotta : AppColors.brown100,
              labelStyle: TextStyle(
                color: _customRange != null ? Colors.white : AppColors.brown700,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: () => setState(() {
                _future = _load();
              }),
              icon: const Icon(Icons.refresh, color: AppColors.brown600),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FutureBuilder<({List<KasaReceipt> rows, ScopedReceiptsSummary summary})>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data!.rows;
            final s = snap.data!.summary;
            if (rows.isEmpty) return const _EmptyKasa();
            final shownCount = widget.voidOnly ? s.iptalSayisi : s.fisSayisi;
            final shownTotal = widget.voidOnly ? s.iptalDeger : s.toplam;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.voidOnly
                      ? '$shownCount iptal fişi  ·  toplam ${formatPrice(shownTotal)}'
                          '${rows.length < shownCount ? ' (son ${rows.length} tanesi listeleniyor)' : ''}'
                      : '$shownCount fiş  ·  toplam ${formatPrice(shownTotal)}'
                          '${rows.length < shownCount ? ' (son ${rows.length} tanesi listeleniyor)' : ''}',
                  style: const TextStyle(color: AppColors.brown600, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                SortableTable<KasaReceipt>(
                  rows: rows,
                  initialSortColumn: 0,
                  initialAscending: false,
                  onRowTap: (r) => _openDetail(context, widget.repo, r),
                  rowTint: (r) => r.isVoid ? AppColors.terracotta.withValues(alpha: 0.07) : null,
                  // Mobile: Fiş No/Ödeme/Ürün/Not made the row scroll well
                  // past a phone's width for columns that are rarely the
                  // reason someone's looking at this table -- Tarih/Tutar
                  // (and Durum, for the not-void-only tab) cover the actual
                  // question ("what sold, when, for how much") on their own.
                  // Desktop keeps every column; there's room for it there.
                  columns: [
                    SortColumn(
                      label: 'Tarih',
                      width: 150,
                      sortKey: (r) => r.soldAt.millisecondsSinceEpoch,
                      cell: (r) => Text('${_dmy(r.soldAt)}  ${_hm(r.soldAt)}',
                          style: const TextStyle(fontSize: 12, color: AppColors.brown600)),
                    ),
                    if (isDesktopPlatform)
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
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: widget.voidOnly ? AppColors.terracotta : AppColors.brown900)),
                    ),
                    if (isDesktopPlatform && !widget.voidOnly)
                      SortColumn(label: 'Ödeme', width: 150, sortKey: (r) => r.paymentLabel, cell: (r) => _PayChip(r)),
                    if (isDesktopPlatform)
                      SortColumn(
                        label: 'Ürün',
                        width: 64,
                        numeric: true,
                        sortKey: (r) => r.lineCount ?? 0,
                        cell: (r) => Text('${r.lineCount ?? '-'}'),
                      ),
                    if (isDesktopPlatform) _noteColumn(widget.repo, widget.notes),
                    if (!widget.voidOnly)
                      SortColumn(
                        label: 'Durum',
                        width: 78,
                        sortKey: (r) => r.isVoid ? 1 : 0,
                        cell: (r) => r.isVoid
                            ? const _Badge('İPTAL', AppColors.terracotta)
                            : const Text('—', style: TextStyle(color: AppColors.brown300)),
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

enum _ScopedRangePreset { today, last7, last30, last90, thisMonth, lastMonth, custom }

/// Kasap/Manav's "Özet" tab -- the scoped equivalent of Günlük Özet, but
/// date-*range* shaped (like the rest of these sections) rather than
/// single-day. Ciro/Satılan Ürün come from the exact, line-level scoped
/// product-sales aggregation; Fiş/Nakit/Kart/İndirim/İptal come from the
/// exact kasa_receipts_summary_for_barcodes aggregate (never row-capped)
/// -- an approximation only in the sense that a receipt with both a scoped
/// item and something else counts its whole payment split, the same kind
/// of approximation the real, whole-store Günlük Özet already makes
/// implicitly. The chart is hourly when the selected range is exactly one
/// day (matching the real Günlük Özet), daily otherwise.
class _ScopedSummarySection extends StatefulWidget {
  final KasaRepo repo;
  final List<String> barcodes;
  const _ScopedSummarySection({required this.repo, required this.barcodes});

  @override
  State<_ScopedSummarySection> createState() => _ScopedSummarySectionState();
}

class _ScopedSummarySectionState extends State<_ScopedSummarySection> {
  _ScopedRangePreset _preset = _ScopedRangePreset.last30;
  late DateTime _from;
  late DateTime _to;
  Future<
      ({
        List<KasaProductSalesReport> sales,
        List<KasaDailyTrendPoint>? dailyTrend,
        List<num>? hourly,
        ScopedReceiptsSummary receiptsSummary,
      })>? _future;

  bool get _isSingleDay => DateUtils.isSameDay(_from, _to);

  @override
  void initState() {
    super.initState();
    _computeDatesForPreset(_preset);
    _reload();
  }

  void _computeDatesForPreset(_ScopedRangePreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (preset) {
      case _ScopedRangePreset.today:
        _from = today;
        _to = today;
      case _ScopedRangePreset.last7:
        _from = today.subtract(const Duration(days: 6));
        _to = today;
      case _ScopedRangePreset.last30:
        _from = today.subtract(const Duration(days: 29));
        _to = today;
      case _ScopedRangePreset.last90:
        _from = today.subtract(const Duration(days: 89));
        _to = today;
      case _ScopedRangePreset.thisMonth:
        _from = DateTime(now.year, now.month, 1);
        _to = today;
      case _ScopedRangePreset.lastMonth:
        final firstOfThisMonth = DateTime(now.year, now.month, 1);
        final lastOfPrevMonth = firstOfThisMonth.subtract(const Duration(days: 1));
        _from = DateTime(lastOfPrevMonth.year, lastOfPrevMonth.month, 1);
        _to = lastOfPrevMonth;
      case _ScopedRangePreset.custom:
        break;
    }
  }

  Future<
      ({
        List<KasaProductSalesReport> sales,
        List<KasaDailyTrendPoint>? dailyTrend,
        List<num>? hourly,
        ScopedReceiptsSummary receiptsSummary,
      })> _load() async {
    // _from/_to are day-precision (local midnight of the first/last day to
    // include). The receipts RPCs compare against sold_at (a timestamptz)
    // with an exclusive upper bound, so _to itself (midnight of the last
    // day) would exclude that entire day -- push the boundary to the start
    // of the *next* day. Product-sales calls compare DATE columns instead
    // (inclusive either end regardless of time-of-day), so they use _to
    // as-is.
    final receiptsTo = _to.add(const Duration(days: 1));
    final sales = await widget.repo.getProductSalesReport(
        from: _from, to: _to, barcodes: widget.barcodes, includeUnsold: false, limit: 1000);
    final receiptsSummary =
        await widget.repo.getReceiptsSummaryForBarcodes(barcodes: widget.barcodes, from: _from, to: receiptsTo);
    if (_isSingleDay) {
      final hourly = await widget.repo.getHourlySalesForBarcodes(barcodes: widget.barcodes, day: _from);
      return (sales: sales, dailyTrend: null, hourly: hourly, receiptsSummary: receiptsSummary);
    }
    final dailyTrend = await widget.repo.getProductSalesDailyTrend(from: _from, to: _to, barcodes: widget.barcodes);
    return (sales: sales, dailyTrend: dailyTrend, hourly: null, receiptsSummary: receiptsSummary);
  }

  void _reload() => setState(() {
        _future = _load();
      });

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
        _preset = _ScopedRangePreset.custom;
        _from = picked.start;
        _to = picked.end;
        _reload();
      });
    }
  }

  String _presetLabel(_ScopedRangePreset p) => switch (p) {
        _ScopedRangePreset.today => 'Bugün',
        _ScopedRangePreset.last7 => 'Son 7 gün',
        _ScopedRangePreset.last30 => 'Son 30 gün',
        _ScopedRangePreset.last90 => 'Son 90 gün',
        _ScopedRangePreset.thisMonth => 'Bu Ay',
        _ScopedRangePreset.lastMonth => 'Geçen Ay',
        _ScopedRangePreset.custom => '${_dm(_from)} - ${_dm(_to)}',
      };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Zaman:',
                style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600, fontSize: 12.5)),
            for (final p in [
              _ScopedRangePreset.today,
              _ScopedRangePreset.last7,
              _ScopedRangePreset.last30,
              _ScopedRangePreset.last90,
              _ScopedRangePreset.thisMonth,
              _ScopedRangePreset.lastMonth,
            ])
              ChoiceChip(
                label: Text(_presetLabel(p)),
                selected: _preset == p,
                onSelected: (_) => setState(() {
                  _preset = p;
                  _computeDatesForPreset(p);
                  _reload();
                }),
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                    color: _preset == p ? Colors.white : AppColors.brown700, fontSize: 11.5, fontWeight: FontWeight.w600),
                backgroundColor: AppColors.brown100,
              ),
            ActionChip(
              label: Text(_preset == _ScopedRangePreset.custom ? _presetLabel(_preset) : 'Özel'),
              onPressed: _pickCustomRange,
              backgroundColor: _preset == _ScopedRangePreset.custom ? AppColors.terracotta : AppColors.brown100,
              labelStyle: TextStyle(
                color: _preset == _ScopedRangePreset.custom ? Colors.white : AppColors.brown700,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FutureBuilder<
            ({
              List<KasaProductSalesReport> sales,
              List<KasaDailyTrendPoint>? dailyTrend,
              List<num>? hourly,
              ScopedReceiptsSummary receiptsSummary,
            })>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 50), child: Center(child: CircularProgressIndicator()));
            }
            final data = snap.data!;
            final s = data.receiptsSummary;
            num ciro = 0, satilanUrun = 0;
            for (final row in data.sales) {
              ciro += row.revenue;
              satilanUrun += row.qty;
            }
            if (data.sales.isEmpty && s.fisSayisi == 0 && s.iptalSayisi == 0) {
              return const _EmptyKasa();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_isSingleDay ? 'Saatlik Ciro' : 'Günlük Ciro',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                const SizedBox(height: 10),
                data.hourly != null
                    ? _HourlyBars(byHour: data.hourly!, height: 260)
                    : _DailyBars(points: data.dailyTrend!, height: 260),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Metric('Ciro', formatPrice(ciro), big: true, color: AppColors.success),
                    _Metric('Fiş', '${s.fisSayisi}'),
                    _Metric('Satılan Ürün', _qty(satilanUrun)),
                    _Metric('Nakit', formatPrice(s.nakit)),
                    _Metric('Kart', formatPrice(s.kart)),
                    _Metric('İndirim', formatPrice(s.indirim), color: s.indirim > 0 ? AppColors.mustard : null),
                    _Metric('İptal', '${s.iptalSayisi}  (${formatPrice(s.iptalDeger)})',
                        color: s.iptalSayisi > 0 ? AppColors.terracotta : null),
                  ],
                ),
                const SizedBox(height: 22),
                const Text('Ürün Dağılımı', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown800)),
                const SizedBox(height: 4),
                Text('Toplam ciro: ${formatPrice(ciro)}', style: const TextStyle(color: AppColors.brown500, fontSize: 12)),
                const SizedBox(height: 10),
                _ProductRevenueBreakdown(rows: data.sales),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Kasap/Manav: a standalone top-level desktop section (and, on mobile,
/// nested inside İstatistik for Furkan/Ahmet) replicating most of
/// İstatistik scoped to a barcode set -- Özet, Son İşlemler, İptaller,
/// Ürün Satışları. Fiyat Uyuşmazlığı and Z Raporları are excluded: the
/// former deliberately dropped as noise for this scoped view, the latter
/// inherently register-wide/day-level, nothing to scope.
/// Body-only (no nested Scaffold/AppBar) -- matches TeraziyeGonderScreen's
/// convention, since HomeShell already supplies one shared AppBar/Scaffold
/// for every screen it dispatches.
class ScopedStatsBody extends StatefulWidget {
  final String title;
  final Future<Set<String>> Function() barcodesResolver;
  const ScopedStatsBody({super.key, required this.title, required this.barcodesResolver});

  @override
  State<ScopedStatsBody> createState() => _ScopedStatsBodyState();
}

class _ScopedStatsBodyState extends State<ScopedStatsBody> with SingleTickerProviderStateMixin {
  final _repo = KasaRepo();
  late final TabController _tab = TabController(length: 4, vsync: this);
  Set<String>? _barcodes;
  Map<String, KasaReceiptNote> _notes = const {};
  StreamSubscription? _notesSub;

  @override
  void initState() {
    super.initState();
    widget.barcodesResolver().then((b) {
      if (mounted) setState(() => _barcodes = b);
    });
    _notesSub = _repo.watchReceiptNotes().listen((map) {
      if (mounted) setState(() => _notes = map);
    });
  }

  @override
  void dispose() {
    _notesSub?.cancel();
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_barcodes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_barcodes!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('${widget.title} için barkod seti bulunamadı.',
              textAlign: TextAlign.center, style: const TextStyle(color: AppColors.brown500)),
        ),
      );
    }
    final barcodes = _barcodes!.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.creamBorder))),
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: AppColors.terracotta,
            unselectedLabelColor: AppColors.brown600,
            indicatorColor: AppColors.terracotta,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
            tabs: const [
              Tab(text: 'Özet'),
              Tab(text: 'Son İşlemler'),
              Tab(text: 'İptaller'),
              Tab(text: 'Ürün Satışları'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _ScopedSummarySection(repo: _repo, barcodes: barcodes),
              _ScopedReceiptsSection(repo: _repo, barcodes: barcodes, notes: _notes, voidOnly: false),
              _ScopedReceiptsSection(repo: _repo, barcodes: barcodes, notes: _notes, voidOnly: true),
              KasapContent(
                repo: _repo,
                barcodesResolver: widget.barcodesResolver,
                emptyMessage: '${widget.title} için barkod seti bulunamadı.',
              ),
            ],
          ),
        ),
      ],
    );
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
      onRowTap: (s) => peekProduct(context, s.barcode),
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
  final Map<String, KasaReceiptNote> notes;
  const _VoidsSection({required this.repo, required this.notes});

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
                    _noteColumn(widget.repo, widget.notes),
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
  late final Stream<List<KasaPriceMismatch>> _openStream = widget.repo.watchOpenMismatches();
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
          'Kasa, kataloğdaki güncel fiyattan farklı bir fiyatla satış yaptığında (son 2 gün) burada listelenir.',
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
            stream: _openStream,
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
      onRowTap: (m) => peekProduct(context, m.barcode),
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
// 6. Ürün Satışları (eski Ölü Stok dahil genel satış raporu)
// ===========================================================================

enum _SalesTimelinePreset {
  today,
  last7,
  last30,
  last90,
  thisMonth,
  lastMonth,
  custom,
}

enum _SalesStatusFilter {
  all,
  soldOnly,
  unsoldOnly,
}

class _UrunSatislariSection extends StatefulWidget {
  final KasaRepo repo;
  const _UrunSatislariSection({required this.repo});

  @override
  State<_UrunSatislariSection> createState() => _UrunSatislariSectionState();
}

class _UrunSatislariSectionState extends State<_UrunSatislariSection> {
  _SalesTimelinePreset _preset = _SalesTimelinePreset.last30;
  late DateTime _from;
  late DateTime _to;

  String? _selectedDepno;
  List<String> _availableDepnos = const [];
  _SalesStatusFilter _statusFilter = _SalesStatusFilter.all;
  bool _requireEverSold = false; // "Geçmişte satılmış" (unsoldOnly modunda)
  final _searchController = TextEditingController();
  String _searchQuery = '';

  late Future<List<KasaProductSalesReport>> _future;

  @override
  void initState() {
    super.initState();
    _computeDatesForPreset(_preset);
    _future = _load();
    _loadDepnos();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _computeDatesForPreset(_SalesTimelinePreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (preset) {
      case _SalesTimelinePreset.today:
        _from = today;
        _to = today;
        break;
      case _SalesTimelinePreset.last7:
        _from = today.subtract(const Duration(days: 6));
        _to = today;
        break;
      case _SalesTimelinePreset.last30:
        _from = today.subtract(const Duration(days: 29));
        _to = today;
        break;
      case _SalesTimelinePreset.last90:
        _from = today.subtract(const Duration(days: 89));
        _to = today;
        break;
      case _SalesTimelinePreset.thisMonth:
        _from = DateTime(now.year, now.month, 1);
        _to = today;
        break;
      case _SalesTimelinePreset.lastMonth:
        final firstOfThisMonth = DateTime(now.year, now.month, 1);
        final lastOfPrevMonth = firstOfThisMonth.subtract(const Duration(days: 1));
        _from = DateTime(lastOfPrevMonth.year, lastOfPrevMonth.month, 1);
        _to = lastOfPrevMonth;
        break;
      case _SalesTimelinePreset.custom:
        break;
    }
  }

  Future<void> _loadDepnos() async {
    final depnos = await widget.repo.getDistinctDepnos();
    if (mounted) setState(() => _availableDepnos = depnos);
  }

  Future<List<KasaProductSalesReport>> _load() {
    return widget.repo.getProductSalesReport(
      from: _from,
      to: _to,
      depno: _selectedDepno,
      includeUnsold: true,
      limit: 1000,
    );
  }

  void _reload() => setState(() {
        _future = _load();
      });

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
        _preset = _SalesTimelinePreset.custom;
        _from = picked.start;
        _to = picked.end;
        _future = _load();
      });
    }
  }

  List<KasaProductSalesReport> _filterRows(List<KasaProductSalesReport> all) {
    var list = all;

    if (_statusFilter == _SalesStatusFilter.soldOnly) {
      list = list.where((r) => r.qty > 0).toList();
    } else if (_statusFilter == _SalesStatusFilter.unsoldOnly) {
      list = list.where((r) => r.qty == 0).toList();
      if (_requireEverSold) {
        list = list.where((r) => r.lastSoldAt != null).toList();
      }
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((r) =>
          r.stockname.toLowerCase().contains(q) ||
          r.barcode.toLowerCase().contains(q)).toList();
    }

    return list;
  }

  String _presetLabel(_SalesTimelinePreset p) => switch (p) {
        _SalesTimelinePreset.today => 'Bugün',
        _SalesTimelinePreset.last7 => 'Son 7 gün',
        _SalesTimelinePreset.last30 => 'Son 30 gün',
        _SalesTimelinePreset.last90 => 'Son 90 gün',
        _SalesTimelinePreset.thisMonth => 'Bu Ay',
        _SalesTimelinePreset.lastMonth => 'Geçen Ay',
        _SalesTimelinePreset.custom =>
          '${_dm(_from)} - ${_dm(_to)}',
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fixed toolbar -- presets + filters stay put; only the table body
          // below scrolls.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
        // 1. Timeline presets row
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Zaman:',
                style: TextStyle(
                    color: AppColors.brown600,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5)),
            for (final p in [
              _SalesTimelinePreset.today,
              _SalesTimelinePreset.last7,
              _SalesTimelinePreset.last30,
              _SalesTimelinePreset.last90,
              _SalesTimelinePreset.thisMonth,
              _SalesTimelinePreset.lastMonth,
            ])
              ChoiceChip(
                label: Text(_presetLabel(p)),
                selected: _preset == p,
                onSelected: (_) {
                  setState(() {
                    _preset = p;
                    _computeDatesForPreset(p);
                    _reload();
                  });
                },
                selectedColor: AppColors.terracotta,
                labelStyle: TextStyle(
                  color: _preset == p ? Colors.white : AppColors.brown700,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
                backgroundColor: AppColors.brown100,
              ),
            ActionChip(
              avatar: const Icon(Icons.date_range, size: 14, color: AppColors.brown700),
              label: Text(
                _preset == _SalesTimelinePreset.custom
                    ? _presetLabel(_SalesTimelinePreset.custom)
                    : 'Özel Aralık...',
              ),
              onPressed: _pickCustomRange,
              backgroundColor: _preset == _SalesTimelinePreset.custom
                  ? AppColors.terracotta
                  : AppColors.brown100,
              labelStyle: TextStyle(
                color: _preset == _SalesTimelinePreset.custom
                    ? Colors.white
                    : AppColors.brown700,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 2. Filters row: Reyon / Durum / Arama
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Reyon Dropdown
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(color: AppColors.creamBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _selectedDepno,
                  hint: const Text('Tüm Reyonlar',
                      style: TextStyle(fontSize: 12, color: AppColors.brown600, fontWeight: FontWeight.w600)),
                  icon: const Icon(Icons.arrow_drop_down, color: AppColors.brown600, size: 18),
                  style: const TextStyle(fontSize: 12, color: AppColors.brown900, fontWeight: FontWeight.w600),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Tüm Reyonlar (KDV)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                    for (final d in _availableDepnos)
                      DropdownMenuItem<String?>(
                        value: d,
                        child: Text(d, style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selectedDepno = v;
                      _reload();
                    });
                  },
                ),
              ),
            ),

            // Satış Durumu ChoiceChips
            ChoiceChip(
              label: const Text('Tümü'),
              selected: _statusFilter == _SalesStatusFilter.all,
              onSelected: (_) => setState(() => _statusFilter = _SalesStatusFilter.all),
              selectedColor: AppColors.brown700,
              labelStyle: TextStyle(
                color: _statusFilter == _SalesStatusFilter.all ? Colors.white : AppColors.brown700,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: AppColors.brown100,
            ),
            ChoiceChip(
              label: const Text('Satılanlar'),
              selected: _statusFilter == _SalesStatusFilter.soldOnly,
              onSelected: (_) => setState(() => _statusFilter = _SalesStatusFilter.soldOnly),
              selectedColor: AppColors.success,
              labelStyle: TextStyle(
                color: _statusFilter == _SalesStatusFilter.soldOnly ? Colors.white : AppColors.brown700,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: AppColors.brown100,
            ),
            ChoiceChip(
              label: const Text('Satılmayanlar (Ölü Stok)'),
              selected: _statusFilter == _SalesStatusFilter.unsoldOnly,
              onSelected: (_) => setState(() => _statusFilter = _SalesStatusFilter.unsoldOnly),
              selectedColor: AppColors.terracotta,
              labelStyle: TextStyle(
                color: _statusFilter == _SalesStatusFilter.unsoldOnly ? Colors.white : AppColors.brown700,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: AppColors.brown100,
            ),

            if (_statusFilter == _SalesStatusFilter.unsoldOnly)
              FilterChip(
                label: const Text('Geçmişte satılmış'),
                selected: _requireEverSold,
                onSelected: (v) => setState(() => _requireEverSold = v),
                selectedColor: AppColors.brown200,
                labelStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),

            // Search filter field
            SizedBox(
              width: 180,
              height: 36,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Ürün veya barkod ara...',
                  hintStyle: const TextStyle(fontSize: 11.5, color: AppColors.brown400),
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 16, color: AppColors.brown500),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 14),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    borderSide: const BorderSide(color: AppColors.creamBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    borderSide: const BorderSide(color: AppColors.creamBorder),
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
          ],
        ),
              ],
            ),
          ),

          // Table -- fills the remaining height; its body scrolls, the pager
          // (when there is more than one page) stays pinned above it.
          Expanded(
            child: FutureBuilder<List<KasaProductSalesReport>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 50),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final all = snap.data!;
            final rows = _filterRows(all);

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
                // Summary bar
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
                      Text(
                        '${rows.length} ürün listeleniyor'
                        '${rows.length != all.length ? ' (${all.length} toplam)' : ''}',
                        style: const TextStyle(
                          color: AppColors.brown800,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Toplam: ${_qty(totalQty)} adet  ·  ${formatPrice(totalRevenue)}  ·  $totalLines işlem',
                        style: const TextStyle(
                          color: AppColors.terracotta,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                Expanded(
                  child: ProductSalesReportTable(
                    rows: rows,
                    pageSize: appSettings.tablePageSize,
                    from: _from,
                    to: _to,
                    repo: widget.repo,
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
