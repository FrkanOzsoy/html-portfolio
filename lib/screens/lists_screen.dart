import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../platform_util.dart';
import '../theme.dart';
import 'list_detail_screen.dart';

class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  final _repo = DataRepo();
  late final Stream<List<ProductList>> _stream = _repo.watchLists();

  Future<void> _openNewListSheet() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _NewListSheet(),
    );
    // No manual refresh needed -- the list stream picks up the new row
    // via realtime as soon as it's inserted.
  }

  void _openList(ProductList list) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ListDetailScreen(listId: list.id)),
    );
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
            SizedBox(
              height: desktop ? 56 : null,
              child: OutlinedButton(
                onPressed: _openNewListSheet,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: AppColors.brown300, width: 2, style: BorderStyle.solid),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.box)),
                ),
                child: Text(
                  '+ Yeni Liste Oluştur',
                  style: TextStyle(color: AppColors.brown600, fontWeight: FontWeight.w600, fontSize: desktop ? 16 : 14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<List<ProductList>>(
                stream: _stream,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final lists = snapshot.data!.where((l) => !reservedTeraziyeListNames.contains(l.name)).toList();
                  if (lists.isEmpty) {
                    return Center(
                      child: Text(
                        'Henüz liste oluşturulmadı.',
                        style: TextStyle(color: AppColors.brown500, fontSize: desktop ? 18 : 14),
                      ),
                    );
                  }
                  // Desktop: a grid instead of a single narrow column -- a
                  // list of one-line cards down the middle of a 1500px-wide
                  // area was most of what made this screen look empty.
                  if (desktop) {
                    return GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 340,
                        mainAxisExtent: 100,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: lists.length,
                      itemBuilder: (context, i) => _ListCard(list: lists[i], onTap: () => _openList(lists[i]), desktop: true),
                    );
                  }
                  return ListView.separated(
                    itemCount: lists.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ListCard(list: lists[i], onTap: () => _openList(lists[i]), desktop: false),
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

class _ListCard extends StatelessWidget {
  final ProductList list;
  final VoidCallback onTap;
  final bool desktop;

  const _ListCard({required this.list, required this.onTap, required this.desktop});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.box),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(desktop ? 18 : 14),
        decoration: BoxDecoration(
          color: AppColors.creamCard,
          borderRadius: BorderRadius.circular(AppRadius.box),
          border: Border.all(color: AppColors.creamBorder),
        ),
        // No more "list type" chip -- lists aren't typed any more, just
        // named, so the name is all this row needs to show.
        child: desktop
            ? Text(
                list.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AppColors.brown900),
              )
            : Text(list.name, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown900)),
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
  final Set<String> _selectedFields = {...defaultStandardListFieldKeys};
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _saving = true);
    try {
      final fields = [
        for (final key in standardListFieldKeys)
          if (_selectedFields.contains(key))
            CustomField(key: key, label: standardListFieldLabels[key]!, inputType: 'text'),
      ];

      // Every new list is just a plain list now -- no more picking a
      // "type" up front (Fiyat Kontrol/Stok Yenileme/...), just which of
      // the product's own fields show on each card, which is also
      // editable later from the list itself (see ListDetailScreen's
      // field-editor action).
      await _repo.createList(name, ListKind.custom, fields);
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Ürünlerde Gösterilecek Bilgiler', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 4),
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
              const SizedBox(height: 8),
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
