import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../format.dart';
import '../models.dart';
import '../platform_util.dart';
import '../theme.dart';
import '../widgets/queued_action_button.dart';
import '../widgets/server_action_button.dart';
import '../widgets/square_icon_button.dart';
import '../widgets/swipe_bounce_dismiss.dart';
import '../widgets/sync_health_banner.dart';
import '../widgets/tab_keep_alive.dart';

/// MANAV/SARKUTERI's item-to-PLU assignment was originally auto-classified
/// by product name and turned out wrong -- sending was disabled until the
/// correct list was uploaded from the till-PC side. That's now done (till-PC
/// session replaced both lists with real store data, confirmed 2026-08-23),
/// so sending is back on.
const _teraziyeSendingEnabled = true;

String _fieldLabel(String field) => switch (field) {
      'price' => 'Fiyat',
      'stockname' => 'İsim',
      'stockunit' => 'Birim',
      'depno' => 'Grup',
      'barcode' => 'Barkod',
      kDeleteField => 'Ürünü Sil',
      _ => field,
    };

/// The value being replaced, for the "old → new" line on a pending card. For
/// a barcode change the "old" is the staged row's own barcode.
String _oldValueDisplay(PendingChange c) => switch (c.field) {
      'price' => formatPrice(c.product?.price),
      'barcode' => c.barcode,
      _ => c.product?.stockname ?? '-',
    };

String _formatValue(String field, String? value) =>
    field == 'price' ? formatPrice(value == null ? null : num.tryParse(value)) : (value ?? '-');

/// The field's actual current value on the (locally cached, but
/// realtime-synced) product row -- null for a field this app doesn't mirror
/// onto [Product] locally (e.g. 'kasadepid', which only exists on the
/// till-PC side), meaning no double-check is possible for it.
String? _currentValueFor(PendingChange c) => switch (c.field) {
      'price' => c.product?.price?.toString(),
      'stockname' => c.product?.stockname,
      'stockunit' => c.product?.stockunit,
      'depno' => c.product?.depno,
      _ => null,
    };

/// True when the product's current value already matches what's staged --
/// almost always because someone already sent this exact change from
/// another device (or another staff member's session) and this staged row
/// itself just hasn't been cleared yet, rather than because it still
/// genuinely needs sending. See _PendingChangeCard's warning below.
bool _alreadyApplied(PendingChange c) {
  if (c.product == null) return false;
  if (c.field == 'price') {
    final staged = num.tryParse(c.newValue.replaceAll(',', '.'));
    return staged != null && c.product!.price == staged;
  }
  final current = _currentValueFor(c);
  return current != null && current == c.newValue;
}

String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _formatFullDateTime(DateTime dt) {
  final local = dt.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Review every staged product edit -- proposed from a list item's pencil
/// icon or directly from "Ürün Ara" -- in one place, pick which ones to
/// actually commit, and send just those through the real Digisoft/kasa
/// pipeline (optionally also queuing an Argox label print). Nothing here
/// reaches the till until one of the send buttons is pressed. The bottom
/// "Eski Gönderilenler" section shows what's already been sent and whether
/// the till-PC service confirmed it landed.
class KasayaGonderScreen extends StatefulWidget {
  const KasayaGonderScreen({super.key});

  @override
  State<KasayaGonderScreen> createState() => _KasayaGonderScreenState();
}

class _KasayaGonderScreenState extends State<KasayaGonderScreen> with SingleTickerProviderStateMixin {
  final _repo = DataRepo();
  List<PendingChange> _latestChanges = [];
  List<PendingProductCreate> _latestCreates = [];
  final Set<String> _selectedIds = {};
  final Set<String> _selectedCreateIds = {};
  bool _sending = false;
  List<SentChangeRecord> _history = [];
  bool _historyLoading = true;
  late final TabController _tabController = TabController(length: 2, vsync: this);
  // Cached once, not re-created every build() -- unlike every other screen's
  // stream field, this used to call _repo.watchAllPendingChanges() fresh
  // inline in the StreamBuilder, which meant switching tabs and back (any
  // rebuild of this State) tore down and re-subscribed a brand new stream
  // each time, instead of reusing the same live one.
  late final Stream<List<PendingChange>> _pendingChangesStream = _repo.watchAllPendingChanges();
  late final Stream<List<PendingProductCreate>> _pendingCreatesStream = _repo.watchAllPendingCreates();
  // Whoever set their name on *this* device (see DataRepo.getStaffName) --
  // there's no real per-user auth (one shared staff account), so "current
  // user" just means "matches this device's own self-reported name". Used
  // to sort that group to the bottom, separate from everyone else's.
  String? _currentStaffName;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _repo.getStaffName().then((name) {
      if (mounted) setState(() => _currentStaffName = name);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() => _historyLoading = true);
    final history = await _repo.getRecentSentChanges();
    if (mounted) {
      setState(() {
        _history = history;
        _historyLoading = false;
      });
    }
  }

  void _toggleSelect(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  Future<void> _revoke(PendingChange change) async {
    setState(() => _selectedIds.remove(change.id));
    await _repo.unstageChange(change.id);
  }

  // Bulk counterpart to the single swipe-to-revoke on each card -- for
  // clearing out a batch of stale/wrong proposals (e.g. someone staged a
  // pile of changes from the wrong list) without swiping them away one at
  // a time. Confirmed first since, unlike a single swipe (already a
  // deliberate gesture), a misclick here could wipe out several people's
  // staged work at once.
  Future<void> _revokeSelected() async {
    final toRevoke = _latestChanges.where((c) => _selectedIds.contains(c.id)).toList();
    final creasToRevoke = _latestCreates.where((c) => _selectedCreateIds.contains(c.id)).toList();
    if (toRevoke.isEmpty && creasToRevoke.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seçilenleri Kaldır'),
        content: Text('${toRevoke.length + creasToRevoke.length} bekleyen öğe kaldırılacak. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.terracotta),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final c in toRevoke) {
      await _repo.unstageChange(c.id);
    }
    for (final c in creasToRevoke) {
      await _repo.unstageProductCreate(c.id);
    }
    if (mounted) {
      setState(() {
        _selectedIds.clear();
        _selectedCreateIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${toRevoke.length + creasToRevoke.length} öğe kaldırıldı.')),
      );
    }
  }

  Future<bool> _sendSelected({required bool alsoPrintLabel}) async {
    // Defense in depth -- the checkbox is already disabled for a conflicted
    // barcode, but a selection made *before* a second person's conflicting
    // change landed could still be sitting in _selectedIds when this fires.
    final requestersByBarcode = <String, Set<String>>{};
    for (final c in _latestChanges) {
      requestersByBarcode.putIfAbsent(c.barcode, () => {}).add(c.requestedBy ?? 'Bilinmeyen Kullanıcı');
    }
    final selected = _latestChanges
        .where((c) => _selectedIds.contains(c.id) && (requestersByBarcode[c.barcode]?.length ?? 1) <= 1)
        .toList();
    final selectedCreates = _latestCreates.where((c) => _selectedCreateIds.contains(c.id)).toList();
    if (selected.isEmpty && selectedCreates.isEmpty) return false;

    setState(() => _sending = true);
    var successCount = 0;
    final errors = <String>[];
    for (final create in selectedCreates) {
      final err = await _repo.sendPendingCreate(create);
      if (err == null) {
        successCount++;
      } else {
        errors.add('${create.stockname} (yeni ürün)');
      }
    }
    for (final change in selected) {
      final err = await _repo.sendPendingChange(change, alsoPrintLabel: alsoPrintLabel);
      if (err == null) {
        successCount++;
      } else {
        errors.add('${change.product?.stockname ?? change.barcode} (${_fieldLabel(change.field)})');
      }
    }
    if (mounted) {
      setState(() {
        _sending = false;
        _selectedIds.clear();
        _selectedCreateIds.clear();
      });
      final message = errors.isEmpty
          ? '$successCount öğe gönderildi.${alsoPrintLabel ? ' Etiketler yazdırılıyor.' : ''}'
          : '$successCount gönderildi, ${errors.length} hata: ${errors.join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      unawaited(_loadHistory());
    }
    return errors.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    // On desktop "Teraziye Gönder" is its own top-menu destination
    // (home_shell.dart's _idTerazi -> TeraziyeGonderScreen), so this screen
    // is just the Kasaya Gönder side -- no inner TabBar. The phone keeps
    // both as tabs here since it has no room for a 6th bottom-nav entry.
    if (isDesktopPlatform) {
      return SafeArea(child: _buildKasayaTab());
    }
    return SafeArea(
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            labelColor: AppColors.terracotta,
            unselectedLabelColor: AppColors.brown500,
            indicatorColor: AppColors.terracotta,
            tabs: const [
              Tab(icon: Icon(Icons.point_of_sale_outlined), text: 'Kasaya Gönder'),
              Tab(icon: Icon(Icons.monitor_weight_outlined), text: 'Teraziye Gönder'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              // Swiping here would fight the app-wide swipe-to-switch-tabs
              // gesture on the main shell (home_shell.dart) -- this inner
              // view only changes tab via the TabBar itself.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                TabKeepAlive(child: _buildKasayaTab()),
                const TabKeepAlive(child: _TeraziyeGonderTab()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKasayaTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SyncHealthBanner(),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<List<PendingProductCreate>>(
                stream: _pendingCreatesStream,
                builder: (context, createSnap) {
                  final creates = createSnap.data ?? [];
                  _latestCreates = creates;
                  _selectedCreateIds.retainAll(creates.map((c) => c.id));
                  return StreamBuilder<List<PendingChange>>(
                stream: _pendingChangesStream,
                builder: (context, snapshot) {
                  final changes = snapshot.data ?? [];
                  _latestChanges = changes;
                  _selectedIds.retainAll(changes.map((c) => c.id));

                  // A barcode with pending changes from more than one
                  // distinct requester (any field, not just the same one --
                  // the deterministic barcode:field id already silently
                  // merges same-field collisions into one overwritten row,
                  // so this is specifically the case that id scheme can't
                  // catch: two different people mid-editing the same
                  // product at once) is unsafe to send blind -- flagged and
                  // blocked from selection until someone reverts theirs.
                  final requestersByBarcode = <String, Set<String>>{};
                  for (final c in changes) {
                    requestersByBarcode.putIfAbsent(c.barcode, () => {}).add(c.requestedBy ?? 'Bilinmeyen Kullanıcı');
                  }
                  final conflictedBarcodes = {
                    for (final e in requestersByBarcode.entries)
                      if (e.value.length > 1) e.key,
                  };
                  final selectableChanges = changes.where((c) => !conflictedBarcodes.contains(c.barcode)).toList();

                  // "Tümünü Seç" spans both the non-conflicted changes and
                  // every staged new product.
                  final selChangeIds = selectableChanges.map((c) => c.id).toSet();
                  final createIds = creates.map((c) => c.id).toSet();
                  final hasAnySelectable = selChangeIds.isNotEmpty || createIds.isNotEmpty;
                  final allSelected = hasAnySelectable &&
                      selChangeIds.every(_selectedIds.contains) &&
                      createIds.every(_selectedCreateIds.contains);

                  // Grouped by who staged it (not by list, like before) --
                  // this is a shared, global staging area (every device
                  // sees every change), so it's easy to mistake someone
                  // else's proposal for your own or vice versa. Other
                  // people's groups sort first (most recently active
                  // first), this device's own group always sorts last.
                  final grouped = <String, List<PendingChange>>{};
                  for (final c in changes) {
                    grouped.putIfAbsent(c.requestedBy ?? 'Bilinmeyen Kullanıcı', () => []).add(c);
                  }
                  DateTime mostRecent(List<PendingChange> group) =>
                      group.map((c) => c.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
                  final groupEntries = grouped.entries.toList()
                    ..sort((a, b) {
                      final aIsMe = a.key == _currentStaffName;
                      final bIsMe = b.key == _currentStaffName;
                      if (aIsMe != bIsMe) return aIsMe ? 1 : -1;
                      return mostRecent(b.value).compareTo(mostRecent(a.value));
                    });

                  return ListView(
                    children: [
                      if (!snapshot.hasData && !createSnap.hasData)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (changes.isEmpty && creates.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'Gönderilecek bekleyen bir şey yok.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.brown500),
                            ),
                          ),
                        ),
                      if (hasAnySelectable) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Material(
                                color: AppColors.brown100,
                                borderRadius: BorderRadius.circular(AppRadius.box),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(AppRadius.box),
                                  onTap: () => setState(() {
                                    if (allSelected) {
                                      _selectedIds.removeAll(selChangeIds);
                                      _selectedCreateIds.removeAll(createIds);
                                    } else {
                                      _selectedIds.addAll(selChangeIds);
                                      _selectedCreateIds.addAll(createIds);
                                    }
                                  }),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: AppColors.brown300, width: 2),
                                      borderRadius: BorderRadius.circular(AppRadius.box),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          allSelected ? Icons.check_box : Icons.check_box_outline_blank,
                                          size: 18,
                                          color: AppColors.brown700,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          allSelected ? 'Seçimi Kaldır' : 'Tümünü Seç',
                                          style: const TextStyle(
                                              color: AppColors.brown700, fontWeight: FontWeight.w700, fontSize: 14),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Discards the *selected* items (creates + changes)
                            // without sending them -- per-item X/swipe still
                            // does one at a time.
                            SquareIconButton(
                              icon: Icons.playlist_remove,
                              color: AppColors.terracotta,
                              tooltip: 'Seçilenleri kaldır',
                              size: 44,
                              onPressed: !_sending && (_selectedIds.isNotEmpty || _selectedCreateIds.isNotEmpty)
                                  ? _revokeSelected
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (creates.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Text('Yeni Ürünler',
                              style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown700, fontSize: 13)),
                        ),
                        for (final create in creates)
                          _PendingCreateCard(
                            create: create,
                            selected: _selectedCreateIds.contains(create.id),
                            onSelectChanged: (v) => setState(() {
                              if (v) {
                                _selectedCreateIds.add(create.id);
                              } else {
                                _selectedCreateIds.remove(create.id);
                              }
                            }),
                            onRevoke: () => _repo.unstageProductCreate(create.id),
                          ),
                        const SizedBox(height: 12),
                      ],
                      if (changes.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${changes.length} bekleyen değişiklik',
                            style: const TextStyle(color: AppColors.brown500, fontSize: 13),
                          ),
                        ),
                        for (final group in groupEntries) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(
                                  group.key == _currentStaffName ? 'Sizin Bekleyen Değişiklikleriniz' : group.key,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: AppColors.brown700, fontSize: 13),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'en son ${_formatFullDateTime(mostRecent(group.value))}',
                                  style: const TextStyle(color: AppColors.brown400, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          for (final c in group.value)
                            SwipeBounceDismiss(
                              itemKey: ValueKey(c.id),
                              onDismiss: () => _revoke(c),
                              builder: (triggerDismiss) => _PendingChangeCard(
                                change: c,
                                selected: _selectedIds.contains(c.id),
                                conflicted: conflictedBarcodes.contains(c.barcode),
                                onSelectChanged: (v) => _toggleSelect(c.id, v),
                                onRevoke: triggerDismiss,
                              ),
                            ),
                        ],
                      ],
                      const SizedBox(height: 24),
                      const Divider(),
                      _SentHistorySection(loading: _historyLoading, history: _history),
                    ],
                  );
                },
              );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ServerActionButton(
                    icon: Icons.point_of_sale,
                    label: 'Kasaya Gönder${(_selectedIds.length + _selectedCreateIds.length) == 0 ? '' : ' (${_selectedIds.length + _selectedCreateIds.length})'}',
                    color: AppColors.brown800,
                    enabled: !_sending && (_selectedIds.isNotEmpty || _selectedCreateIds.isNotEmpty),
                    onPressed: () => _sendSelected(alsoPrintLabel: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ServerActionButton(
                    icon: Icons.print_outlined,
                    label: 'Gönder ve Etiket Bastır',
                    color: AppColors.brown800,
                    enabled: !_sending && _selectedIds.isNotEmpty,
                    onPressed: () => _sendSelected(alsoPrintLabel: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
  }
}

/// Desktop-only standalone screen for the Teraziye Gönder flow -- on a
/// phone this same [_TeraziyeGonderTab] lives as the second tab inside
/// [KasayaGonderScreen]; on desktop it's a top-menu destination of its own
/// (home_shell.dart's _idTerazi).
class TeraziyeGonderScreen extends StatelessWidget {
  const TeraziyeGonderScreen({super.key});

  @override
  Widget build(BuildContext context) => const SafeArea(child: _TeraziyeGonderTab());
}

/// Per-item editable working copy for the Teraziye Gönder flow -- plain
/// controllers, not staged anywhere, since these edits only ever matter for
/// the one export payload built at send time (see
/// _TeraziyeGonderTabState._submit).
class _TeraziyeItemState {
  final ListItem item;
  final TextEditingController nameController;
  final TextEditingController priceController;

  _TeraziyeItemState(this.item)
      : nameController = TextEditingController(text: item.product?.stockname ?? ''),
        priceController = TextEditingController(text: item.product?.price?.toString() ?? '');

  // The scale's own PLU (list_items.custom_data.plu) -- sequential per list
  // (MANAV and SARKUTERI each start their own numbering at 1), not
  // Digisoft's general stock code (products.pluno). Read straight off the
  // item since it's display-only here, not editable.
  String? get plu => item.customData['plu']?.toString();

  void dispose() {
    nameController.dispose();
    priceController.dispose();
  }
}

class _TeraziyeGonderTab extends StatefulWidget {
  const _TeraziyeGonderTab();

  @override
  State<_TeraziyeGonderTab> createState() => _TeraziyeGonderTabState();
}

class _TeraziyeGonderTabState extends State<_TeraziyeGonderTab> {
  final _repo = DataRepo();
  // Teraziye only ever works with these two fixed, dedicated lists (real
  // rows in `lists`, same table Listelerim uses, but hidden from
  // Listelerim's own browsing -- see reservedTeraziyeListNames) -- not the
  // general list catalog, so staff can't accidentally send an unrelated
  // shopping list to the scale.
  late final Future<List<ProductList>> _listsFuture = _repo.getReservedTeraziyeLists();
  String? _selectedListId;
  ProductList? _selectedList;
  List<ListItem> _items = [];
  bool _itemsLoading = false;
  final Map<String, _TeraziyeItemState> _itemStates = {};

  @override
  void initState() {
    super.initState();
    // Open on MANAV by default -- it's the list staff reach for most, and
    // landing on a blank "Liste seçin" every time was an extra click every
    // single visit. Falls back to whatever's first if MANAV isn't present.
    _listsFuture.then((lists) {
      if (!mounted || lists.isEmpty || _selectedListId != null) return;
      final manav = lists.firstWhere(
        (l) => l.name.toUpperCase() == 'MANAV',
        orElse: () => lists.first,
      );
      _selectList(manav);
    });
  }

  @override
  void dispose() {
    for (final s in _itemStates.values) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _selectList(ProductList list) async {
    for (final s in _itemStates.values) {
      s.dispose();
    }
    setState(() {
      _selectedListId = list.id;
      _selectedList = list;
      _itemsLoading = true;
      _items = [];
      _itemStates.clear();
    });
    final items = await _repo.getListItems(list.id);
    if (!mounted) return;
    // Scale lists are worked through in PLU order (that's how they're laid
    // out on the physical scale's key sheet), so default to that rather
    // than the scanned_at order getListItems returns.
    int pluOf(ListItem it) => int.tryParse('${it.customData['plu'] ?? ''}') ?? 1 << 30;
    items.sort((a, b) => pluOf(a).compareTo(pluOf(b)));
    setState(() {
      _items = items;
      _itemsLoading = false;
      for (final item in items) {
        _itemStates[item.id] = _TeraziyeItemState(item);
      }
    });
  }

  /// Pressing "Teraziye Gönder" does two independent things:
  ///  1. stages any name/price corrections into Kasaya Gönder (they reach
  ///     Digisoft only once sent from there -- like every other kasa action),
  ///  2. writes the scale file: the till-PC regenerates CASLP16.PLU from
  ///     Digisoft's *current* rows by reyon name. So after sending the
  ///     staged changes from Kasaya Gönder, press this again for an
  ///     up-to-date file.
  Future<int> _submit() async {
    final list = _selectedList;
    if (list == null) throw StateError('Liste seçilmedi');
    for (final item in _items) {
      final st = _itemStates[item.id]!;
      final product = item.product;
      if (product == null) continue;
      final newName = st.nameController.text.trim();
      final newPrice = num.tryParse(st.priceController.text.trim().replaceAll(',', '.'));
      if (newName.isNotEmpty && newName != product.stockname) {
        await _repo.stageChange(
            barcode: product.barcode, field: 'stockname', value: newName, listName: 'Terazi · ${list.name}');
      }
      if (newPrice != null && newPrice != product.price) {
        await _repo.stageChange(
            barcode: product.barcode, field: 'price', value: newPrice.toString(), listName: 'Terazi · ${list.name}');
      }
    }
    return _repo.requestEslExport(listName: list.name, itemCount: _items.length);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      // stretch (not the default center) so the pinned send-button bar
      // below always gets a tight, bounded width -- without it the Row of
      // Expanded buttons inside could end up unconstrained and vanish at
      // some window sizes. Matches _buildKasayaTab's own column.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SyncHealthBanner(),
          const SizedBox(height: 16),
          if (!_teraziyeSendingEnabled)
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.terracotta.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadius.box),
                border: Border.all(color: AppColors.terracotta, width: 2),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.terracotta, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'BU ÖZELLİK HENÜZ TAMAMLANMADI',
                          style: TextStyle(
                            color: AppColors.terracotta,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'MANAV/ŞARKÜTERİ ürün listeleri yanlış -- doğru liste kasa bilgisayarından yüklenene kadar gönderim kapatıldı.',
                          style: TextStyle(color: AppColors.brown700, fontSize: 12.5, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          FutureBuilder<List<ProductList>>(
            future: _listsFuture,
            builder: (context, snapshot) {
              final lists = snapshot.data ?? [];
              return DropdownButtonFormField<String>(
                initialValue: _selectedListId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Liste'),
                hint: Text(snapshot.connectionState == ConnectionState.waiting ? 'Yükleniyor…' : 'Liste seçin'),
                items: [
                  for (final l in lists) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (id) {
                  final l = lists.firstWhere((l) => l.id == id);
                  _selectList(l);
                },
              );
            },
          ),
          const SizedBox(height: 16),
          if (_itemsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_selectedList != null && _items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('Bu listede ürün yok.', style: TextStyle(color: AppColors.brown500))),
            )
          else
            for (final item in _items)
              if (_itemStates[item.id] != null) _TeraziyeItemCard(state: _itemStates[item.id]!),
        ],
            ),
          ),
        ),
        // Pinned outside the ScrollView so it's always reachable without
        // scrolling down through however many items the list has.
        if (_items.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            decoration: BoxDecoration(
              color: AppColors.cream,
              border: Border(top: BorderSide(color: AppColors.creamBorder)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Terazi dosyasını günceller; düzeltilen isim/fiyatlar Kasaya Gönder\'e eklenir.',
                    style: TextStyle(fontSize: 11.5, color: AppColors.brown500),
                  ),
                  const SizedBox(height: 8),
                  QueuedActionButton(
                    icon: Icons.monitor_weight_outlined,
                    label: 'Teraziye Gönder',
                    enabled: _teraziyeSendingEnabled,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    onSubmit: _submit,
                    watchStatus: _repo.watchEslExportStatus,
                    // Reload once it's through so the fields refresh to the
                    // staged values -- otherwise a second press would stage
                    // every diff again.
                    onFinished: (status) {
                      if (status != 'done') return;
                      final l = _selectedList;
                      if (l != null) _selectList(l);
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// Whole list always goes -- no per-item send/skip choice any more -- and
// only name/price are editable here (barcode and PLU are fixed identifiers,
// not something staff should be retyping on the way to the scale). Shown
// as plain text instead of TextFields, which is also what shrinks the
// card down to a size where "Teraziye Gönder" doesn't take a screenful of
// scrolling to reach.
class _TeraziyeItemCard extends StatelessWidget {
  final _TeraziyeItemState state;

  const _TeraziyeItemCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final plu = state.plu;
    // Desktop's wide row left the price field stranded at a phone-sized 90px
    // next to a name field that stretched the whole window -- proportionally
    // it read as an afterthought. Give it real width and a bigger, bolder
    // figure there (it's the one value staff are actually checking on the
    // way to the scale); the phone layout is unchanged.
    final desktop = isDesktopPlatform;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: desktop ? 2 : 3,
            child: TextField(
              controller: state.nameController,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: desktop ? 16 : 14, color: AppColors.brown900),
              decoration: const InputDecoration(labelText: 'İsim', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: desktop ? 160 : 90,
            child: TextField(
              controller: state.priceController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(
                  fontSize: desktop ? 18 : 13,
                  fontWeight: desktop ? FontWeight.bold : FontWeight.normal,
                  color: AppColors.brown900),
              decoration: const InputDecoration(labelText: 'Fiyat (₺)', isDense: true),
            ),
          ),
          if (plu != null && plu.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text('PLU $plu', style: TextStyle(fontSize: desktop ? 13 : 11, color: AppColors.brown400)),
          ],
        ],
      ),
    );
  }
}

/// A new product staged for creation, waiting in the Kasaya Gönder queue --
/// the create-side counterpart of [_PendingChangeCard].
class _PendingCreateCard extends StatelessWidget {
  final PendingProductCreate create;
  final bool selected;
  final ValueChanged<bool> onSelectChanged;
  final VoidCallback onRevoke;

  const _PendingCreateCard({
    required this.create,
    required this.selected,
    required this.onSelectChanged,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: selected ? AppColors.terracotta : AppColors.creamBorder, width: selected ? 2 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) => onSelectChanged(v ?? false),
            activeColor: AppColors.terracotta,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.add_circle, size: 15, color: AppColors.success),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(create.stockname,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.brown900)),
                    ),
                  ],
                ),
                Text(create.barcode, style: const TextStyle(fontSize: 13, color: AppColors.brown500)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Yeni ürün · ${formatPrice(create.price)}'
                    '${create.stockunit != null && create.stockunit!.isNotEmpty ? ' · ${create.stockunit}' : ''}'
                    ' · ${_formatTime(create.createdAt)}',
                    style: const TextStyle(fontSize: 11, color: AppColors.brown400, fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ),
          SquareIconButton(
            icon: Icons.close,
            color: AppColors.brown400,
            tooltip: 'Kaldır',
            size: 28,
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}

class _PendingChangeCard extends StatelessWidget {
  final PendingChange change;
  final bool selected;
  /// True when another product_pending_changes row for this *same barcode*
  /// (any field) was staged by a different requester -- two people
  /// mid-editing the same product at once. Blocked from selection until
  /// one side reverts theirs, since sending blind here risks clobbering
  /// whichever change loses.
  final bool conflicted;
  final ValueChanged<bool> onSelectChanged;
  final VoidCallback onRevoke;

  const _PendingChangeCard({
    required this.change,
    required this.selected,
    required this.conflicted,
    required this.onSelectChanged,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final alreadyApplied = _alreadyApplied(change);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: conflicted ? AppColors.terracotta.withValues(alpha: 0.10) : AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(
          color: conflicted || alreadyApplied || selected ? AppColors.terracotta : AppColors.creamBorder,
          width: conflicted ? 2.5 : (alreadyApplied || selected ? 2 : 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: conflicted ? null : (v) => onSelectChanged(v ?? false),
            activeColor: AppColors.terracotta,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  change.product?.stockname ?? change.barcode,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.brown900),
                ),
                Text(change.barcode, style: const TextStyle(fontSize: 13, color: AppColors.brown500)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    // Who staged this is now shown once, on the group
                    // header above, instead of repeated per card -- this is
                    // the source list (or "Ürün Ara" if staged straight
                    // from search) and exactly when, which the group header
                    // doesn't carry.
                    '${change.sourceListName ?? 'Ürün Ara'} · ${_formatTime(change.createdAt)}',
                    style: const TextStyle(fontSize: 11, color: AppColors.brown400, fontStyle: FontStyle.italic),
                  ),
                ),
                const SizedBox(height: 6),
                if (change.field == kDeleteField)
                  Row(
                    children: [
                      const Icon(Icons.delete_forever, size: 15, color: AppColors.terracotta),
                      const SizedBox(width: 4),
                      Text(
                        'Bu ürün Digisoft\'tan silinecek',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.terracotta),
                      ),
                    ],
                  )
                else
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 12, color: AppColors.brown500),
                      children: [
                        TextSpan(
                          text: '${_fieldLabel(change.field)}: ${_oldValueDisplay(change)}  →  ',
                        ),
                        TextSpan(
                          text: _formatValue(change.field, change.newValue),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.terracotta),
                        ),
                      ],
                    ),
                  ),
                if (alreadyApplied && change.field != kDeleteField)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, size: 14, color: AppColors.terracotta),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Kasadaki ${_fieldLabel(change.field).toLowerCase()} zaten güncellenmiş: '
                            '${_formatValue(change.field, _currentValueFor(change))} -- muhtemelen zaten gönderilmiş.',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.terracotta, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (conflicted)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.terracotta),
                        const SizedBox(width: 4),
                        const Expanded(
                          child: Text(
                            'Bu üründe başka bir kullanıcının da bekleyen değişikliği var -- '
                            'biri geri alınmadan gönderilemez.',
                            style: TextStyle(fontSize: 11, color: AppColors.terracotta, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SquareIconButton(
            icon: Icons.close,
            color: AppColors.terracotta,
            tooltip: 'Değişikliği Kaldır',
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}

/// "Eski Gönderilenler" -- collapsed by default. Sends fired from the same
/// batch (same sender, same minute) are grouped under one collapsible
/// header so a multi-item send doesn't flood the list.
class _SentHistorySection extends StatefulWidget {
  final bool loading;
  final List<SentChangeRecord> history;

  const _SentHistorySection({required this.loading, required this.history});

  @override
  State<_SentHistorySection> createState() => _SentHistorySectionState();
}

class _SentHistorySectionState extends State<_SentHistorySection> {
  bool _expanded = false;

  Map<String, List<SentChangeRecord>> _grouped() {
    final grouped = <String, List<SentChangeRecord>>{};
    for (final r in widget.history) {
      final key = '${r.requestedBy ?? "?"}|${_formatTime(r.at)}';
      grouped.putIfAbsent(key, () => []).add(r);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _grouped();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: AppColors.brown700),
                const SizedBox(width: 4),
                const Text(
                  'Eski Gönderilenler',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.brown800),
                ),
                if (!_expanded && widget.history.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text('(${widget.history.length})', style: const TextStyle(color: AppColors.brown400, fontSize: 13)),
                ],
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const Text(
            '"Gönderildi" = servis Digisoft\'a yazıp kasaya iletti.',
            style: TextStyle(color: AppColors.brown400, fontSize: 11),
          ),
          const SizedBox(height: 8),
          if (widget.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (widget.history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz gönderim yok.', style: TextStyle(color: AppColors.brown500, fontSize: 13)),
            )
          else
            for (final entry in groups.entries) _SentHistoryGroup(groupKey: entry.key, records: entry.value),
        ],
      ],
    );
  }
}

class _SentHistoryGroup extends StatefulWidget {
  final String groupKey;
  final List<SentChangeRecord> records;

  const _SentHistoryGroup({required this.groupKey, required this.records});

  @override
  State<_SentHistoryGroup> createState() => _SentHistoryGroupState();
}

class _SentHistoryGroupState extends State<_SentHistoryGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final anyError = widget.records.any((r) => r.status != 'done');
    final color = anyError ? AppColors.terracotta : AppColors.success;
    final parts = widget.groupKey.split('|');
    final who = parts[0];
    final when = parts.length > 1 ? parts[1] : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: color, size: 20),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '$who · $when',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color),
                    ),
                  ),
                  Text('${widget.records.length} değişiklik', style: const TextStyle(fontSize: 11, color: AppColors.brown400)),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final r in widget.records) _SentHistoryRow(record: r)],
              ),
            ),
        ],
      ),
    );
  }
}

class _SentHistoryRow extends StatelessWidget {
  final SentChangeRecord record;
  const _SentHistoryRow({required this.record});

  @override
  Widget build(BuildContext context) {
    final done = record.status == 'done';
    final color = done ? AppColors.success : AppColors.terracotta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(done ? Icons.check_circle : Icons.error, color: color, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.stockname ?? record.barcode,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppColors.brown900),
                ),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 12, color: AppColors.brown500),
                    children: [
                      TextSpan(text: '${_fieldLabel(record.field)}: ${_formatValue(record.field, record.oldValue)}  →  '),
                      TextSpan(
                        text: _formatValue(record.field, record.newValue),
                        style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.terracotta),
                      ),
                    ],
                  ),
                ),
                if (!done && record.errorMessage != null)
                  Text(record.errorMessage!, style: TextStyle(fontSize: 11, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
