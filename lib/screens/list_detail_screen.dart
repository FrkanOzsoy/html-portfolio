import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/edit_product_button.dart';
import '../widgets/export_sheet.dart';
import '../widgets/pop_in.dart';
import '../widgets/print_label_button.dart';
import '../widgets/square_icon_button.dart';
import '../widgets/swipe_bounce_dismiss.dart';
import '../widgets/undo_banner.dart';

class ListDetailScreen extends StatefulWidget {
  final String listId;
  const ListDetailScreen({super.key, required this.listId});

  @override
  State<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<ListDetailScreen> {
  final _repo = DataRepo();
  ProductList? _list;
  late final Stream<List<ListItem>> _itemsStream = _repo.watchListItems(widget.listId);

  @override
  void initState() {
    super.initState();
    _loadListMeta();
  }

  Future<void> _loadListMeta() async {
    final list = await _repo.getListById(widget.listId);
    if (mounted) setState(() => _list = list);
  }

  Future<void> _deleteItem(ListItem item) async {
    // No manual reload -- the items stream reflects the delete via realtime.
    await _repo.deleteListItem(item.id);
    await _repo.logAction('urun_listeden_silindi', detail: item.id);
    if (!mounted) return;
    showUndoSnackBar(
      ScaffoldMessenger.of(context),
      message: '${item.product?.stockname ?? item.barcode} listeden kaldırıldı',
      onUndo: () => _repo.restoreListItem(item),
    );
  }

  // No confirm dialog -- the undo banner (same as removing a single item)
  // is the safety net now, not a blocking "are you sure". Since this pops
  // back to Listelerim (nothing left to show once the list is gone), the
  // messenger has to be grabbed before popping -- this screen's own
  // BuildContext is defunct the instant Navigator.pop() runs.
  Future<void> _deleteList() async {
    final list = _list!;
    final items = List<ListItem>.from(_latestItems);
    final messenger = ScaffoldMessenger.of(context);
    await _repo.deleteList(list.id);
    if (!mounted) return;
    Navigator.of(context).pop();
    showUndoSnackBar(
      messenger,
      message: '"${list.name}" listesi silindi',
      onUndo: () => _repo.restoreList(list, items),
    );
  }

  List<ListItem> _latestItems = [];

  Future<void> _openExportSheet() =>
      showExportSheet(context, list: _list!, items: _latestItems);

  // Lets a list's info fields be changed after creation instead of only at
  // creation time -- only meaningful for a plain (ListKind.custom) list,
  // since that's the only kind whose per-item form is driven by `fields`
  // at all (see _ItemCard.build's `if (widget.list.type == ListKind.custom)`
  // branch); the older built-in list kinds keep their fixed Miktar/Yeni
  // Fiyat/Not field regardless.
  Future<void> _editFields() async {
    final list = _list!;
    final fields = await showModalBottomSheet<List<CustomField>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _EditFieldsSheet(initialFields: list.fields),
    );
    if (fields == null || !mounted) return;
    await _repo.updateListFields(list.id, fields);
    await _loadListMeta();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: Text(list?.name ?? '', overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          if (list != null) ...[
            if (list.type == ListKind.custom)
              IconButton(icon: const Icon(Icons.tune), tooltip: 'Alanları Düzenle', onPressed: _editFields),
            IconButton(icon: const Icon(Icons.ios_share), tooltip: 'Dışa Aktar', onPressed: _openExportSheet),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: _DeleteListButton(onPressed: _deleteList)),
            ),
          ],
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Only the older built-in list kinds still have a
                    // meaningful type name to show -- a plain (custom) list
                    // has no "type" any more from the user's side, just
                    // whatever fields it was given (see _editFields).
                    if (list.type != ListKind.custom) ...[
                      Text(list.type.label, style: const TextStyle(color: AppColors.brown500)),
                      const SizedBox(height: 12),
                    ] else ...[
                      // Right in the list itself, not just tucked behind the
                      // app bar's tune icon -- shows what's currently picked
                      // and doubles as the entry point to change it.
                      InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        onTap: _editFields,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.tune, size: 15, color: AppColors.brown500),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  list.fields.isEmpty
                                      ? 'Gösterilecek bilgi seçilmedi -- düzenlemek için dokunun'
                                      : 'Gösterilen: ${list.fields.map((f) => f.label).join(', ')}',
                                  style: const TextStyle(color: AppColors.brown500, fontSize: 12.5),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.chevron_right, size: 16, color: AppColors.brown400),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Expanded(
                      child: StreamBuilder<List<ListItem>>(
                        stream: _itemsStream,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final items = snapshot.data!;
                          _latestItems = items;
                          if (items.isEmpty) {
                            return const Center(
                              child: Text(
                                'Bu listede henüz ürün yok.\nTarayıcı veya Ürün Ara sekmesinden ekleyin.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.brown500),
                              ),
                            );
                          }
                          return ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (context, i) => SwipeBounceDismiss(
                              itemKey: ValueKey(items[i].id),
                              onDismiss: () => _deleteItem(items[i]),
                              builder: (triggerDismiss) => PopIn(
                                child: _ItemCard(
                                  item: items[i],
                                  list: list,
                                  onDelete: triggerDismiss,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Top-bar delete action for the whole list -- icon-only now (was
/// icon+"Sil" label) so it doesn't crowd out the other app bar actions
/// (Alanları Düzenle, Dışa Aktar) on narrower phones.
class _DeleteListButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _DeleteListButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Listeyi Sil',
      child: Material(
        color: AppColors.terracotta,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.delete_outline, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _ItemCard extends StatefulWidget {
  final ListItem item;
  final ProductList list;
  final VoidCallback onDelete;

  const _ItemCard({required this.item, required this.list, required this.onDelete});

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  final _repo = DataRepo();
  late final TextEditingController _fieldController;
  StreamSubscription<List<PendingChange>>? _pendingSub;
  List<PendingChange> _pending = [];
  late bool _noteEditing;

  // A plain (ListKind.custom) list's `fields` are now just a set of tick
  // boxes for which of the product's own name/barcode/price/kdv to show --
  // no per-item typed data any more (see _buildProductInfo).
  Set<String> get _visibleStandardFields => widget.list.type == ListKind.custom
      ? widget.list.fields.map((f) => f.key).toSet()
      : standardListFieldKeys.toSet();

  @override
  void initState() {
    super.initState();
    _fieldController = TextEditingController(
      text: switch (widget.list.type) {
        ListKind.restock => widget.item.quantity?.toString() ?? '',
        ListKind.priceChange => widget.item.newPrice?.toString() ?? '',
        ListKind.priceCheck => widget.item.note ?? '',
        ListKind.custom => '',
      },
    );
    _noteEditing = (widget.item.note ?? '').trim().isNotEmpty;
    _pendingSub = _repo.watchPendingChangesForBarcode(widget.item.barcode).listen((changes) {
      if (mounted) setState(() => _pending = changes);
    });
  }

  @override
  void dispose() {
    _fieldController.dispose();
    _pendingSub?.cancel();
    super.dispose();
  }

  PendingChange? _pendingFor(String field) {
    for (final c in _pending) {
      if (c.field == field) return c;
    }
    return null;
  }

  Future<void> _clearPending(String field) async {
    final existing = _pendingFor(field);
    if (existing != null) await _repo.unstageChange(existing.id);
  }

  // Returns success/failure for ServerActionButton -- which already shows
  // its own green "Kaydedildi" confirmation on the button itself, so this
  // no longer needs a separate SnackBar or its own busy-state tracking.
  Future<bool> _save() async {
    try {
      switch (widget.list.type) {
        case ListKind.restock:
          final v = _fieldController.text.trim();
          await _repo.updateItemQuantity(widget.item.id, v.isEmpty ? null : num.tryParse(v));
        case ListKind.priceChange:
          final v = _fieldController.text.trim();
          await _repo.updateItemNewPrice(widget.item.id, v.isEmpty ? null : num.tryParse(v));
        case ListKind.priceCheck:
          await _repo.updateItemNote(widget.item.id, _fieldController.text);
        case ListKind.custom:
          break; // nothing to save -- fields here are display-only tick boxes now
      }
      await _repo.logAction('urun_guncellendi', detail: widget.item.barcode);
      // Collapse the note back to display mode after a successful save --
      // matches _deleteNote's immediate local update below.
      if (widget.list.type == ListKind.priceCheck && mounted) setState(() => _noteEditing = false);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _cancelNoteEdit() {
    setState(() {
      _fieldController.text = widget.item.note ?? '';
      _noteEditing = false;
    });
  }

  Future<void> _deleteNote() async {
    setState(() => _fieldController.text = '');
    await _repo.updateItemNote(widget.item.id, '');
    await _repo.logAction('urun_guncellendi', detail: widget.item.barcode);
  }

  String? get _kdvLabel {
    final rate = widget.item.product?.kdvRate;
    if (rate == null) return null;
    return '%${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 2)} KDV';
  }

  String get _fieldLabel => switch (widget.list.type) {
        ListKind.restock => 'Miktar',
        ListKind.priceChange => 'Yeni Fiyat',
        ListKind.priceCheck => 'Not',
        ListKind.custom => '',
      };

  @override
  Widget build(BuildContext context) {
    final isNumeric = widget.list.type == ListKind.restock || widget.list.type == ListKind.priceChange;
    final isPriceCheck = widget.list.type == ListKind.priceCheck;
    final hasNote = isPriceCheck && !_noteEditing && (widget.item.note ?? '').trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_visibleStandardFields.contains('name')) ...[
                      Text(
                        widget.item.product?.stockname ?? 'Ürün bulunamadı',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900),
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (_visibleStandardFields.contains('barcode')) ...[
                      SelectableText(
                        widget.item.barcode,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.brown600),
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (_visibleStandardFields.contains('price') ||
                        (_visibleStandardFields.contains('kdv') && _kdvLabel != null))
                      Wrap(
                        spacing: 6,
                        children: [
                          if (_visibleStandardFields.contains('price'))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                  color: AppColors.brown100, borderRadius: BorderRadius.circular(AppRadius.chip)),
                              child: Text(
                                formatPrice(widget.item.product?.price),
                                style:
                                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.brown800),
                              ),
                            ),
                          if (_visibleStandardFields.contains('kdv') && _kdvLabel != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                  color: AppColors.brown100, borderRadius: BorderRadius.circular(AppRadius.chip)),
                              child: Text(
                                _kdvLabel!,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brown600),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              SquareIconButton(
                icon: Icons.delete_outline,
                color: AppColors.terracotta,
                tooltip: 'Sil',
                onPressed: widget.onDelete,
              ),
            ],
          ),
          if (_pending.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.mustard.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.box),
                border: Border.all(color: AppColors.mustard.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_pendingFor('stockname') != null)
                    _comparisonRow(
                      'İsim',
                      widget.item.product?.stockname ?? '-',
                      _pendingFor('stockname')!.newValue,
                      () => _clearPending('stockname'),
                    ),
                  if (_pendingFor('price') != null)
                    _comparisonRow(
                      'Fiyat',
                      formatPrice(widget.item.product?.price),
                      formatPrice(num.tryParse(_pendingFor('price')!.newValue)),
                      () => _clearPending('price'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          // A plain (custom) list has no editable field here at all any
          // more -- its `fields` just toggle which of the product's own
          // attributes show above (see _visibleStandardFields).
          if (isPriceCheck) ...[
            if (_noteEditing)
              TextField(
                controller: _fieldController,
                maxLines: 2,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Not',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              )
            else if (hasNote)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.brown100,
                  borderRadius: BorderRadius.circular(AppRadius.box),
                  border: Border.all(color: AppColors.creamBorder),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        widget.item.note!,
                        style: const TextStyle(fontSize: 13, color: AppColors.brown800),
                      ),
                    ),
                    SquareIconButton(
                      icon: Icons.close,
                      color: AppColors.terracotta,
                      tooltip: 'Notu Sil',
                      size: 28,
                      onPressed: _deleteNote,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ] else if (widget.list.type != ListKind.custom) ...[
            TextField(
              controller: _fieldController,
              keyboardType: isNumeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(labelText: _fieldLabel, isDense: true),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: EditProductButton(
                  product: widget.item.product,
                  sourceListId: widget.list.id,
                  sourceListName: widget.list.name,
                ),
              ),
              const SizedBox(width: 6),
              if (isPriceCheck) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _noteEditing ? _cancelNoteEdit : () => setState(() => _noteEditing = true),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.brown300, width: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                    ),
                    icon: Icon(
                      _noteEditing ? Icons.close : (hasNote ? Icons.edit_note : Icons.note_add_outlined),
                      size: 18,
                      color: AppColors.brown700,
                    ),
                    label: Text(
                      _noteEditing ? 'İptal' : (hasNote ? 'Notu Düzenle' : 'Not Ekle'),
                      style: const TextStyle(color: AppColors.brown700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: SizedBox(height: 48, child: PrintLabelButton(barcode: widget.item.barcode)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _comparisonRow(String label, String oldValue, String newValue, VoidCallback onCancel) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, color: AppColors.brown500),
                children: [
                  TextSpan(text: '$label: $oldValue  →  '),
                  TextSpan(
                    text: newValue,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.terracotta),
                  ),
                ],
              ),
            ),
          ),
          SquareIconButton(
            icon: Icons.close,
            color: AppColors.brown400,
            tooltip: 'Öneriyi İptal Et',
            onPressed: onCancel,
            size: 28,
          ),
        ],
      ),
    );
  }
}

/// Same tick-box shape as _NewListSheet in lists_screen.dart, just
/// pre-filled from a list's existing selection and returning the edited
/// set instead of creating a new list.
class _EditFieldsSheet extends StatefulWidget {
  final List<CustomField> initialFields;
  const _EditFieldsSheet({required this.initialFields});

  @override
  State<_EditFieldsSheet> createState() => _EditFieldsSheetState();
}

class _EditFieldsSheetState extends State<_EditFieldsSheet> {
  late final Set<String> _selectedFields = {
    for (final f in widget.initialFields)
      if (standardListFieldKeys.contains(f.key)) f.key,
  };

  void _submit() {
    final fields = [
      for (final key in standardListFieldKeys)
        if (_selectedFields.contains(key))
          CustomField(key: key, label: standardListFieldLabels[key]!, inputType: 'text'),
    ];
    Navigator.of(context).pop(fields);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ürünlerde Gösterilecek Bilgiler',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
              const SizedBox(height: 12),
              for (final key in standardListFieldKeys)
                CheckboxListTile(
                  value: _selectedFields.contains(key),
                  onChanged: (v) => setState(() {
                    if (v ?? false) {
                      _selectedFields.add(key);
                    } else {
                      _selectedFields.remove(key);
                    }
                  }),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(standardListFieldLabels[key]!),
                ),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _submit, child: const Text('Kaydet')),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
