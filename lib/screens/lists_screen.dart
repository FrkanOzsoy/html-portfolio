import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';
import 'list_detail_screen.dart';

class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  final _repo = DataRepo();
  late Future<List<ProductList>> _future;

  @override
  void initState() {
    super.initState();
    _future = _repo.getLists();
  }

  void _refresh() => setState(() => _future = _repo.getLists());

  Future<void> _openNewListSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _NewListSheet(),
    );
    if (created == true) _refresh();
  }

  Future<void> _openList(ProductList list) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ListDetailScreen(listId: list.id)),
    );
    _refresh();
  }

  static const _typeAccent = {
    ListKind.priceCheck: AppColors.terracotta,
    ListKind.restock: AppColors.olive,
    ListKind.priceChange: AppColors.mustard,
    ListKind.custom: AppColors.brown500,
  };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton(
              onPressed: _openNewListSheet,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppColors.brown300, width: 2, style: BorderStyle.solid),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('+ Yeni Liste Oluştur', style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<ProductList>>(
                future: _future,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final lists = snapshot.data!;
                  if (lists.isEmpty) {
                    return const Center(
                      child: Text('Henüz liste oluşturulmadı.', style: TextStyle(color: AppColors.brown500)),
                    );
                  }
                  return ListView.separated(
                    itemCount: lists.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final l = lists[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _openList(l),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.creamCard,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.creamBorder),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown900)),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _typeAccent[l.type]!.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  l.type.label,
                                  style: TextStyle(color: _typeAccent[l.type], fontWeight: FontWeight.w600, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewListSheet extends StatefulWidget {
  const _NewListSheet();

  @override
  State<_NewListSheet> createState() => _NewListSheetState();
}

class _NewListSheetState extends State<_NewListSheet> {
  final _repo = DataRepo();
  final _nameController = TextEditingController();
  ListKind _type = ListKind.priceCheck;
  final List<TextEditingController> _fieldLabelControllers = [TextEditingController()];
  final List<String> _fieldTypes = ['text'];
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    for (final c in _fieldLabelControllers) {
      c.dispose();
    }
    super.dispose();
  }

  String _slugify(String label, int i) {
    const foldMap = {'ı': 'i', 'ğ': 'g', 'ü': 'u', 'ş': 's', 'ö': 'o', 'ç': 'c'};
    final ascii = label
        .toLowerCase()
        .replaceAllMapped(RegExp(r'[ığüşöç]'), (m) => foldMap[m.group(0)]!)
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return ascii.isEmpty ? 'alan_${i + 1}' : ascii;
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _saving = true);
    try {
      final fields = _type == ListKind.custom
          ? [
              for (var i = 0; i < _fieldLabelControllers.length; i++)
                if (_fieldLabelControllers[i].text.trim().isNotEmpty)
                  CustomField(
                    key: _slugify(_fieldLabelControllers[i].text.trim(), i),
                    label: _fieldLabelControllers[i].text.trim(),
                    inputType: _fieldTypes[i],
                  ),
            ]
          : <CustomField>[];

      await _repo.createList(name, _type, fields);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Liste oluşturulamadı.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Yeni Liste', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Liste Adı', hintText: 'Örn: Hafta sonu fiyat kontrolü'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ListKind>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Liste Türü'),
                items: ListKind.values
                    .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v ?? ListKind.priceCheck),
              ),
              if (_type == ListKind.custom) ...[
                const SizedBox(height: 12),
                const Align(alignment: Alignment.centerLeft, child: Text('Özel Alanlar', style: TextStyle(fontWeight: FontWeight.w600))),
                for (var i = 0; i < _fieldLabelControllers.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _fieldLabelControllers[i],
                            decoration: const InputDecoration(hintText: 'Alan adı (örn: Not)', isDense: true),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _fieldTypes[i],
                          items: const [
                            DropdownMenuItem(value: 'text', child: Text('Metin')),
                            DropdownMenuItem(value: 'number', child: Text('Sayı')),
                          ],
                          onChanged: (v) => setState(() => _fieldTypes[i] = v ?? 'text'),
                        ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: () => setState(() {
                    _fieldLabelControllers.add(TextEditingController());
                    _fieldTypes.add('text');
                  }),
                  child: const Text('+ Alan Ekle'),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Oluştur'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
