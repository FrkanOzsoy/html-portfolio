import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_settings.dart';
import '../data_repo.dart';
import '../format.dart';
import '../models.dart';
import '../normalize.dart';
import '../platform_util.dart';
import '../theme.dart';
import '../widgets/add_to_list_button.dart';
import '../widgets/edit_product_button.dart';
import '../widgets/print_label_button.dart';
import '../widgets/square_icon_button.dart';
import 'product_create_screen.dart';
import 'product_edit_screen.dart';

enum _SortField { name, barcode, price, unit, kdv }

/// Fast, keyboard-only price/name-*staging* loop matching how staff already
/// work in Digisoft for the typing/data-entry part: type a barcode, Enter
/// opens this dialog pre-selected on the top match, type the new price
/// straight over the old one, Enter stages it and closes -- focus lands
/// right back on the search box for the next barcode. Also reused as the
/// "little edit menu" opened by double-clicking a row in the desktop
/// table -- same dialog, just triggered a different way. Real commits to
/// Digisoft/kasa only ever happen from "Kasaya Gönder" -- same
/// [DataRepo.stageChange] as product_edit_screen.dart's Kaydet, just
/// reachable without leaving the search results or touching the mouse.
Future<bool?> _showQuickEditDialog(BuildContext context, Product product) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _QuickEditDialog(product: product),
  );
}

class _QuickEditDialog extends StatefulWidget {
  final Product product;
  const _QuickEditDialog({required this.product});

  @override
  State<_QuickEditDialog> createState() => _QuickEditDialogState();
}

class _QuickEditDialogState extends State<_QuickEditDialog> {
  final _repo = DataRepo();
  late final TextEditingController _priceController =
      TextEditingController(text: widget.product.price?.toString() ?? '');
  late final TextEditingController _nameController = TextEditingController(text: widget.product.stockname);
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pre-selected (not just pre-filled) so the very first keystroke
    // replaces the old price outright -- no manual select-all/backspace
    // needed, matching "change the price without touching anything else".
    _priceController.selection = TextSelection(baseOffset: 0, extentOffset: _priceController.text.length);
  }

  @override
  void dispose() {
    _priceController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final text = _priceController.text.trim().replaceAll(',', '.');
    final price = num.tryParse(text);
    if (price == null || price <= 0) {
      setState(() => _error = 'Geçerli bir fiyat girin.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (price != widget.product.price) {
        await _repo.stageChange(barcode: widget.product.barcode, field: 'price', value: text);
      }
      final newName = _nameController.text.trim();
      if (newName.isNotEmpty && newName != widget.product.stockname) {
        await _repo.stageChange(barcode: widget.product.barcode, field: 'stockname', value: newName);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Kaydedilemedi, tekrar deneyin.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(false),
      },
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.box)),
        // Dialog has no width cap of its own -- a Column of TextFields
        // happily stretches to fill (screen width - insetPadding), which
        // on a wide desktop window meant this "little popup" was nearly
        // the whole screen. A compact fixed width is what actually reads
        // as a popup rather than another full page.
        child: SizedBox(
          width: 360,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.product.barcode, style: const TextStyle(fontSize: 13, color: AppColors.brown500)),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Ürün Adı', isDense: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priceController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(labelText: 'Yeni Fiyat (₺)', isDense: true, errorText: _error),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.brown300, width: 2)),
                      child: const Text('Vazgeç', style: TextStyle(color: AppColors.brown700)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _submit,
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800),
                      child: _saving
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Kaydet'),
                    ),
                  ),
                ],
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _repo = DataRepo();
  final _controller = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _tableFocusNode = FocusNode();
  final _tableScrollController = ScrollController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _loading = false;

  // Desktop-only table state (see platform_util.dart) -- selection is kept
  // by barcode rather than tied to `_results`, so it survives across
  // successive searches, letting staff search "domates", tick a few, search
  // "elma", tick a few more, then add/print everything in one batch.
  final Set<String> _selectedBarcodes = {};
  int? _focusedIndex;
  // Manual double-click tracking instead of GestureDetector's onDoubleTap --
  // a widget with both onTap and onDoubleTap makes Flutter hold every
  // single tap for ~300ms (the double-tap timeout) before firing onTap, to
  // see if a second tap is coming. That's what read as "clunky/slow": every
  // row click. Tracking taps by hand lets a single click respond instantly
  // while still recognizing a genuine double-click.
  DateTime? _lastRowTapTime;
  int? _lastRowTapIndex;

  // Sort state -- shared by the desktop table's clickable column headers
  // and the mobile sort-picker sheet (see _showSortSheet). Deliberately
  // not a filter: nothing is ever hidden, only reordered, so there's no
  // "no results match" state to design around like the earlier filter-bar
  // version had. KDV sorts on Product.kdvRate, synced straight from
  // Digisoft (TBLSTOKLAR.SATISKDV via the till-PC bridge) as of 2026-08-23
  // -- no local derivation needed any more.
  _SortField? _sortField;
  bool _sortAscending = true;

  @override
  void dispose() {
    _controller.dispose();
    _searchFocusNode.dispose();
    _tableFocusNode.dispose();
    _tableScrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  List<Product> get _sortedResults {
    final field = _sortField;
    if (field == null) return _results;
    final list = [..._results];
    int cmp(Product a, Product b) {
      switch (field) {
        case _SortField.name:
          return normalizeTurkish(a.stockname).compareTo(normalizeTurkish(b.stockname));
        case _SortField.barcode:
          final an = int.tryParse(a.barcode);
          final bn = int.tryParse(b.barcode);
          if (an != null && bn != null) return an.compareTo(bn);
          return a.barcode.compareTo(b.barcode);
        case _SortField.price:
          return (a.price ?? -1).compareTo(b.price ?? -1);
        case _SortField.unit:
          return (a.stockunit ?? '').compareTo(b.stockunit ?? '');
        case _SortField.kdv:
          return (a.kdvRate ?? -1).compareTo(b.kdvRate ?? -1);
      }
    }

    list.sort(cmp);
    return _sortAscending ? list : list.reversed.toList();
  }

  // Clicking the same column again flips direction (Excel's own
  // behavior); clicking a different column starts it fresh, ascending.
  void _toggleSort(_SortField field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = true;
      }
    });
  }

  Future<void> _showSortSheet() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => _SortPickerSheet(
          sortField: _sortField,
          ascending: _sortAscending,
          onSelect: (field) {
            _toggleSort(field);
            Navigator.of(context).pop();
          },
          onClear: () {
            setState(() => _sortField = null);
            Navigator.of(context).pop();
          },
        ),
      );

  // Enter on the search field acts on the top match -- the fast, keyboard-
  // only Digisoft-style loop: type/scan a barcode, Enter to edit its price,
  // Enter again to commit, land right back here ready for the next one.
  // Runs its own search synchronously rather than trusting whatever
  // `_results` already holds -- a physical barcode-scanner "keyboard
  // wedge" fires the whole barcode plus Enter as one fast burst, often
  // faster than the 250ms debounce in [_onChanged] ever gets to fire, so
  // `_results` could still be empty or stale from an earlier query.
  Future<void> _handleSubmit(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    setState(() => _loading = true);
    List<Product> results;
    try {
      results = await _repo.searchProducts(query);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted || results.isEmpty) return;
    setState(() {
      _results = results;
      _focusedIndex = null;
    });
    final changed = await _showQuickEditDialog(context, results.first);
    if (!mounted) return;
    if (changed == true) {
      _controller.clear();
      setState(() => _results = []);
    }
    _searchFocusNode.requestFocus();
  }

  // Guards against an older, slower query's result landing after a newer
  // one and clobbering it -- only matters once queries can overlap, which
  // dropping the debounce below (desktop) makes possible.
  int _searchRequestId = 0;

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = [];
        _loading = false;
        _focusedIndex = null;
      });
      return;
    }
    if (isDesktopPlatform) {
      // Desktop searches the local catalog (see DataRepo.searchProducts) --
      // cheap enough to run on every keystroke with no debounce and no
      // network-latency reason to throttle it, which is what makes the
      // list actually feel instant instead of visibly catching up.
      final requestId = ++_searchRequestId;
      _repo.searchProducts(value).then((results) {
        if (!mounted || requestId != _searchRequestId) return;
        setState(() {
          _results = results;
          // Focus the top row straight away so the bottom-bar actions work
          // on it without ticking a checkbox first (see _actionTargets).
          _focusedIndex = results.isEmpty ? null : 0;
        });
        if (_tableScrollController.hasClients) _tableScrollController.jumpTo(0);
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final results = await _repo.searchProducts(value);
        if (mounted) setState(() { _results = results; _focusedIndex = null; });
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  // ---- desktop-only: table selection, keyboard nav, batch actions ----

  void _toggleSelect(String barcode) {
    setState(() {
      if (_selectedBarcodes.contains(barcode)) {
        _selectedBarcodes.remove(barcode);
      } else {
        _selectedBarcodes.add(barcode);
      }
    });
  }

  // Move the keyboard-focused row and, only if it would land outside the
  // currently visible window, jump the list by a page (so the row you just
  // moved to sits at the edge of a fresh page) rather than nudging the
  // scroll on every single arrow press.
  void _moveFocus(int index, int rowCount) {
    setState(() => _focusedIndex = index);
    if (!_tableScrollController.hasClients) return;
    final pos = _tableScrollController.position;
    if (pos.maxScrollExtent <= 0 || rowCount == 0) return; // list fits, nothing to scroll
    // All rows are the same height, so this recovers it exactly.
    final rowH = (pos.maxScrollExtent + pos.viewportDimension) / rowCount;
    if (rowH <= 0) return;
    final rowTop = index * rowH;
    final rowBottom = rowTop + rowH;
    double? target;
    if (rowBottom > pos.pixels + pos.viewportDimension) {
      target = rowTop; // stepped past the bottom -> new page, focused row on top
    } else if (rowTop < pos.pixels) {
      target = rowBottom - pos.viewportDimension; // past the top -> focused row on bottom
    }
    if (target != null) {
      _tableScrollController.animateTo(
        target.clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
  }

  KeyEventResult _handleTableKey(KeyEvent event) {
    final rows = _sortedResults;
    if (event is! KeyDownEvent || rows.isEmpty) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveFocus(_focusedIndex == null ? 0 : (_focusedIndex! + 1).clamp(0, rows.length - 1), rows.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveFocus(_focusedIndex == null ? 0 : (_focusedIndex! - 1).clamp(0, rows.length - 1), rows.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        if (_focusedIndex != null) _toggleSelect(rows[_focusedIndex!].barcode);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_focusedIndex != null) _showQuickEditDialog(context, rows[_focusedIndex!]);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// What the bottom-bar actions (Yazdır / Listeye Ekle) operate on: the
  /// checkbox selection when there is one, otherwise -- for convenience --
  /// just the row the keyboard is currently on, so you can arrow down to a
  /// product and act on it without ticking it first.
  List<String> _actionTargets() {
    if (_selectedBarcodes.isNotEmpty) return _selectedBarcodes.toList();
    final rows = _sortedResults;
    final i = _focusedIndex;
    if (i != null && i >= 0 && i < rows.length) return [rows[i].barcode];
    return const [];
  }

  /// "Düzenle" edits exactly one product -- the single ticked row, or (with
  /// nothing ticked) the focused row. Ambiguous with a multi-selection.
  Product? _editTarget() {
    final rows = _sortedResults;
    if (_selectedBarcodes.length == 1) {
      for (final p in rows) {
        if (p.barcode == _selectedBarcodes.first) return p;
      }
      return null;
    }
    if (_selectedBarcodes.isEmpty) {
      final i = _focusedIndex;
      if (i != null && i >= 0 && i < rows.length) return rows[i];
    }
    return null;
  }

  Future<void> _addSelectedToList() async {
    final barcodes = _actionTargets();
    if (barcodes.isEmpty) return;
    final hadSelection = _selectedBarcodes.isNotEmpty;
    List<ProductList> lists;
    try {
      lists = await _repo.getLists();
    } catch (_) {
      lists = [];
    }
    if (!mounted) return;
    if (lists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Henüz liste yok. Önce Listelerim sekmesinden bir liste oluşturun.')),
      );
      return;
    }
    final selectedList = await showModalBottomSheet<ProductList>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _DesktopListPickerSheet(lists: lists, count: barcodes.length),
    );
    if (selectedList == null || !mounted) return;
    var successCount = 0;
    for (final barcode in barcodes) {
      try {
        await _repo.addListItem(selectedList.id, barcode);
        successCount++;
      } catch (_) {
        // Best-effort -- keep going so one bad item doesn't stop the batch.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$successCount/${barcodes.length} ürün "${selectedList.name}" listesine eklendi.')),
      );
      if (hadSelection) setState(() => _selectedBarcodes.clear());
    }
  }

  Future<void> _printSelected() async {
    final barcodes = _actionTargets();
    if (barcodes.isEmpty) return;
    for (final barcode in barcodes) {
      unawaited(_repo.requestLabelPrint(barcode, 1));
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${barcodes.length} ürün için etiket isteği gönderildi.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopPlatform;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Focus(
                    // Desktop only -- lets Down-arrow hand off from typing a
                    // query straight into browsing the table below, without
                    // swallowing any other key the TextField needs itself.
                    onKeyEvent: !desktop
                        ? null
                        : (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey == LogicalKeyboardKey.arrowDown &&
                                _results.isNotEmpty) {
                              setState(() => _focusedIndex = 0);
                              _tableFocusNode.requestFocus();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                    child: TextField(
                      controller: _controller,
                      focusNode: _searchFocusNode,
                      autofocus: true,
                      onChanged: _onChanged,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _handleSubmit,
                      decoration: const InputDecoration(
                        hintText: 'Barkod veya ürün adı yazın (örn: pınar, PINAR, 8690...)',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                ),
                // Mobile only: a sort button (desktop sorts via the table's
                // clickable column headers) and a "new product" shortcut
                // (desktop has "Yeni Ürün Oluştur" in the top menu already,
                // so the inline + is just clutter there).
                if (!desktop) ...[
                  const SizedBox(width: 8),
                  if (_results.isNotEmpty) ...[
                    SquareIconButton(
                      icon: Icons.sort,
                      color: _sortField != null ? AppColors.terracotta : AppColors.brown700,
                      tooltip: 'Sırala',
                      size: 48,
                      onPressed: _showSortSheet,
                    ),
                    const SizedBox(width: 8),
                  ],
                  SquareIconButton(
                    icon: Icons.add_circle_outline,
                    color: AppColors.brown700,
                    tooltip: 'Yeni Ürün Oluştur',
                    size: 48,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProductCreateScreen(
                          initialBarcode:
                              RegExp(r'^\d+$').hasMatch(_controller.text.trim()) ? _controller.text.trim() : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: Text('Aranıyor…', style: TextStyle(color: AppColors.brown400)))
                  : _controller.text.trim().isEmpty
                      ? const _SearchEmptyPrompt()
                      : _results.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Sonuç bulunamadı.', style: TextStyle(color: AppColors.brown500)),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ProductCreateScreen(
                                          initialBarcode: RegExp(r'^\d+$').hasMatch(_controller.text.trim())
                                              ? _controller.text.trim()
                                              : null,
                                        ),
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: AppColors.brown300, width: 2),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                    ),
                                    icon: const Icon(Icons.add_circle_outline, size: 18, color: AppColors.brown700),
                                    label: const Text('Yeni Ürün Oluştur', style: TextStyle(color: AppColors.brown700)),
                                  ),
                                ],
                              ),
                            )
                          : desktop
                              ? _buildDesktopTable()
                              : ListView.separated(
                                  itemCount: _sortedResults.length,
                                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                                  itemBuilder: (context, i) => _ResultCard(product: _sortedResults[i]),
                                ),
            ),
            if (desktop && _controller.text.trim().isNotEmpty && _results.isNotEmpty) _buildDesktopBottomBar(),
          ],
        ),
      ),
    );
  }

  // Excel's own click-a-column-header-to-sort behavior -- highlighted in
  // terracotta with an up/down arrow when it's the active sort column,
  // plain brown otherwise. Tapping again flips direction (_toggleSort).
  Widget _sortHeaderCell(String label, _SortField field, {TextAlign align = TextAlign.left}) {
    final active = _sortField == field;
    final color = active ? AppColors.terracotta : AppColors.brown800;
    final content = [
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color))),
      if (active) ...[
        const SizedBox(width: 2),
        Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: AppColors.terracotta),
      ],
    ];
    return InkWell(
      onTap: () => _toggleSort(field),
      child: Row(
        mainAxisAlignment: switch (align) {
          TextAlign.center => MainAxisAlignment.center,
          TextAlign.right => MainAxisAlignment.end,
          _ => MainAxisAlignment.start,
        },
        children: content,
      ),
    );
  }

  Widget _buildDesktopTable() {
    return Focus(
      focusNode: _tableFocusNode,
      onKeyEvent: (node, event) => _handleTableKey(event),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.creamBorder),
          borderRadius: BorderRadius.circular(AppRadius.box),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              color: AppColors.brown100,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(width: 32),
                  Expanded(flex: 3, child: _sortHeaderCell('Ürün Adı', _SortField.name)),
                  SizedBox(width: 190, child: _sortHeaderCell('Barkod', _SortField.barcode)),
                  SizedBox(width: 120, child: _sortHeaderCell('Fiyat', _SortField.price, align: TextAlign.right)),
                  SizedBox(width: 70, child: _sortHeaderCell('Birim', _SortField.unit, align: TextAlign.center)),
                  SizedBox(width: 90, child: _sortHeaderCell('KDV', _SortField.kdv, align: TextAlign.center)),
                ],
              ),
            ),
            // One SelectionArea around the whole body (not per-cell) --
            // this is what makes a drag actually span multiple rows, like
            // dragging down a column in Excel, rather than being trapped
            // inside whichever single cell the drag started in. Row
            // tap/double-tap (via the InkWell in _buildDesktopRow) still
            // works alongside it -- SelectionArea only claims drags that
            // start on rendered text, plain taps still reach the InkWell.
            Expanded(
              child: SelectionArea(
                child: ListenableBuilder(
                  listenable: appSettings,
                  builder: (context, _) => ListView.builder(
                    controller: _tableScrollController,
                    itemCount: _sortedResults.length,
                    itemBuilder: (context, i) => _buildDesktopRow(i),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleRowTap(int i, Product product) {
    final now = DateTime.now();
    final isDoubleClick =
        _lastRowTapIndex == i && _lastRowTapTime != null && now.difference(_lastRowTapTime!) < const Duration(milliseconds: 400);
    _lastRowTapTime = isDoubleClick ? null : now; // reset so a 3rd quick tap doesn't chain into another "double"
    _lastRowTapIndex = i;
    setState(() => _focusedIndex = i);
    _tableFocusNode.requestFocus();
    // Double-click opens the full editor (same as the "Düzenle" button);
    // Enter opens the price/name quick-edit dialog (see _handleTableKey).
    if (isDoubleClick) _openFullEditor(product);
  }

  void _openFullEditor(Product product) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProductEditScreen(product: product)),
    );
  }

  Widget _buildDesktopRow(int i) {
    final product = _sortedResults[i];
    final selected = _selectedBarcodes.contains(product.barcode);
    final focused = i == _focusedIndex;
    return InkWell(
      onTap: () => _handleRowTap(i, product),
      child: Container(
        decoration: BoxDecoration(
          color: focused ? AppColors.terracotta.withValues(alpha: 0.12) : (i.isEven ? Colors.white : AppColors.creamCard),
          border: const Border(bottom: BorderSide(color: AppColors.creamBorder, width: 0.5)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: appSettings.rowVerticalPadding),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Checkbox(
                value: selected,
                onChanged: (_) => setState(() {
                  _focusedIndex = i;
                  _toggleSelect(product.barcode);
                }),
                activeColor: AppColors.terracotta,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                product.stockname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: AppColors.brown900),
              ),
            ),
            SizedBox(
              width: 190,
              child: Text(
                product.barcode,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.brown700, fontFamily: 'monospace'),
              ),
            ),
            SizedBox(
              width: 120,
              child: Text(
                formatPrice(product.price),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.brown900),
              ),
            ),
            SizedBox(
              width: 70,
              child: Text(
                product.stockunit ?? '-',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.brown600),
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                product.kdvRate != null ? '%${product.kdvRate!.toStringAsFixed(product.kdvRate! % 1 == 0 ? 0 : 2)}' : '-',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.brown600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopBottomBar() {
    final hasSelection = _selectedBarcodes.isNotEmpty;
    // With nothing ticked, the actions fall back to the focused row (see
    // _actionTargets) so they're still usable straight off the keyboard.
    final canAct = _actionTargets().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              hasSelection
                  ? '${_selectedBarcodes.length} ürün seçili'
                  : (canAct ? 'Odaktaki ürün' : ''),
              style: const TextStyle(color: AppColors.brown500, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 150,
            child: EditProductButton(product: _editTarget()),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 160,
            child: OutlinedButton.icon(
              onPressed: canAct ? _printSelected : null,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.brown300, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.print_outlined, size: 18, color: AppColors.brown700),
              label: const Text('Yazdır', style: TextStyle(color: AppColors.brown700)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 200,
            child: ElevatedButton.icon(
              onPressed: canAct ? _addSelectedToList : null,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800, padding: const EdgeInsets.symmetric(vertical: 14)),
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('Listeye Ekle'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bare-bones list picker for the desktop batch "Listeye Ekle" -- unlike
/// [AddToListButton]'s own picker sheet (single product, optional note),
/// this adds many different products at once, so a single shared note
/// field doesn't make sense the same way; just pick the destination list.
class _DesktopListPickerSheet extends StatelessWidget {
  final List<ProductList> lists;
  final int count;
  const _DesktopListPickerSheet({required this.lists, required this.count});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
        ),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '$count Ürünü Listeye Ekle',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: lists.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final l = lists[i];
                  return ListTile(
                    title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown900)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: l.type.accentColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                      child: Text(l.type.label, style: TextStyle(color: l.type.accentColor, fontWeight: FontWeight.w600, fontSize: 12)),
                    ),
                    onTap: () => Navigator.of(context).pop(l),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Mobile's equivalent of clicking a desktop table's column header --
/// there's no header row on the card list to click, so this sheet picks
/// which field to sort by. Tapping a field that's already active flips its
/// direction (same _toggleSort the desktop headers use), matching "click
/// again for the inverse" on both platforms.
class _SortPickerSheet extends StatelessWidget {
  final _SortField? sortField;
  final bool ascending;
  final ValueChanged<_SortField> onSelect;
  final VoidCallback onClear;

  const _SortPickerSheet({required this.sortField, required this.ascending, required this.onSelect, required this.onClear});

  static const _fields = [
    (field: _SortField.name, label: 'Ürün Adı', ascLabel: 'A-Z', descLabel: 'Z-A'),
    (field: _SortField.barcode, label: 'Barkod', ascLabel: 'Küçükten Büyüğe', descLabel: 'Büyükten Küçüğe'),
    (field: _SortField.price, label: 'Fiyat', ascLabel: 'Düşükten Yükseğe', descLabel: 'Yüksekten Düşüğe'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Sırala', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
            ),
            const Divider(height: 1),
            for (final f in _fields)
              ListTile(
                title: Text(f.label, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown900)),
                subtitle: Text(sortField == f.field ? (ascending ? f.ascLabel : f.descLabel) : f.ascLabel, style: const TextStyle(fontSize: 12)),
                trailing: sortField == f.field
                    ? Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward, color: AppColors.terracotta)
                    : null,
                onTap: () => onSelect(f.field),
              ),
            if (sortField != null)
              ListTile(
                title: const Text('Sıralamayı Kaldır', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown600)),
                leading: const Icon(Icons.close, color: AppColors.brown600),
                onTap: onClear,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Shown on cold launch, before anything's been typed -- was previously
/// just a blank area, which read as broken rather than "waiting for
/// input". Same visual language as the other empty states in the app
/// (scanner_screen.dart's camera-off placeholder, kasaya_gonder_screen.dart's
/// "nothing pending" message).
class _SearchEmptyPrompt extends StatelessWidget {
  const _SearchEmptyPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: AppColors.terracotta.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: const Icon(Icons.search, size: 36, color: AppColors.terracotta),
          ),
          const SizedBox(height: 14),
          const Text(
            'Barkod okutun veya ürün adı yazın',
            style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            'Sonuçlar burada görünecek',
            style: TextStyle(color: AppColors.brown400, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final Product product;
  const _ResultCard({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            product.stockname,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.brown900),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  product.barcode,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.brown700),
                ),
              ),
              SquareIconButton(
                icon: Icons.copy_outlined,
                color: AppColors.brown600,
                tooltip: 'Barkodu Kopyala',
                size: 32,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: product.barcode));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Barkod kopyalandı.'), duration: Duration(seconds: 1)),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: AppColors.brown100, borderRadius: BorderRadius.circular(AppRadius.chip)),
            child: Text(
              formatPrice(product.price),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.brown800),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: AddToListButton(product: product)),
              const SizedBox(width: 8),
              Expanded(child: EditProductButton(product: product)),
              const SizedBox(width: 8),
              Expanded(child: SizedBox(height: 48, child: PrintLabelButton(barcode: product.barcode))),
            ],
          ),
        ],
      ),
    );
  }
}
