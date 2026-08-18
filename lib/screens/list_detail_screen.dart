import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

class ListDetailScreen extends StatefulWidget {
  final String listId;
  const ListDetailScreen({super.key, required this.listId});

  @override
  State<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<ListDetailScreen> {
  final _repo = DataRepo();
  ProductList? _list;
  List<ListItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final lists = await _repo.getLists();
    final list = lists.firstWhere((l) => l.id == widget.listId);
    final items = await _repo.getListItems(widget.listId);
    if (!mounted) return;
    setState(() {
      _list = list;
      _items = items;
      _loading = false;
    });
  }

  Future<void> _deleteItem(String itemId) async {
    await _repo.deleteListItem(itemId);
    _load();
  }

  Future<void> _deleteList() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Listeyi Sil'),
        content: Text('"${_list!.name}" listesini silmek istediğinize emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil', style: TextStyle(color: AppColors.terracotta)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _repo.deleteList(widget.listId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _exportCsv() async {
    final csv = _repo.buildCsv(_list!, _items);
    final dir = await getTemporaryDirectory();
    final safeName = _list!.name.replaceAll(RegExp(r'[^a-z0-9ığüşöç ]', caseSensitive: false), '_');
    final file = File('${dir.path}/$safeName.csv');
    await file.writeAsBytes(utf8.encode(csv));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: _list!.name));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_list?.name ?? ''),
        actions: [
          if (!_loading)
            IconButton(icon: const Icon(Icons.ios_share), tooltip: 'CSV Paylaş', onPressed: _exportCsv),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_list!.type.label, style: const TextStyle(color: AppColors.brown500)),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _items.isEmpty
                          ? const Center(
                              child: Text(
                                'Bu listede henüz ürün yok.\nTarayıcı veya Ürün Ara sekmesinden ekleyin.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.brown500),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (context, i) => _ItemCard(
                                item: _items[i],
                                list: _list!,
                                onDelete: () => _deleteItem(_items[i].id),
                                onSaved: _load,
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _deleteList,
                      child: const Text('Listeyi Sil', style: TextStyle(color: AppColors.terracotta, fontWeight: FontWeight.w600)),
                    ),
                  ],
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
  final VoidCallback onSaved;

  const _ItemCard({required this.item, required this.list, required this.onDelete, required this.onSaved});

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  final _repo = DataRepo();
  late final TextEditingController _fieldController;
  late final Map<String, TextEditingController> _customControllers;
  bool _saving = false;

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
    _customControllers = {
      for (final f in widget.list.fields)
        f.key: TextEditingController(text: widget.item.customData[f.key]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    _fieldController.dispose();
    for (final c in _customControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
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
          await _repo.updateItemCustomData(
            widget.item.id,
            {for (final e in _customControllers.entries) e.key: e.value.text},
          );
      }
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.product?.stockname ?? 'Ürün bulunamadı',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown900),
                    ),
                    Text('Barkod: ${widget.item.barcode}', style: const TextStyle(color: AppColors.brown500, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.terracotta),
                onPressed: widget.onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.list.type == ListKind.custom)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in widget.list.fields)
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _customControllers[f.key],
                      keyboardType: f.inputType == 'number' ? TextInputType.number : TextInputType.text,
                      decoration: InputDecoration(labelText: f.label, isDense: true),
                    ),
                  ),
              ],
            )
          else
            TextField(
              controller: _fieldController,
              keyboardType: isNumeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
              decoration: InputDecoration(labelText: _fieldLabel, isDense: true),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
              child: _saving
                  ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Kaydet'),
            ),
          ),
        ],
      ),
    );
  }
}
