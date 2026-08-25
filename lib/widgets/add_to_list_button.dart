import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

/// Single "Listeye Ekle" button, shared by the scanner and search screens.
/// Tapping it opens a bottom-sheet list picker rather than showing an inline
/// dropdown on every product card.
class AddToListButton extends StatefulWidget {
  final Product product;

  const AddToListButton({super.key, required this.product});

  @override
  State<AddToListButton> createState() => _AddToListButtonState();
}

class _AddToListButtonState extends State<AddToListButton> {
  final _repo = DataRepo();
  bool _busy = false;

  Future<void> _openPicker() async {
    setState(() => _busy = true);
    List<ProductList> lists;
    try {
      lists = await _repo.getLists();
    } catch (_) {
      lists = [];
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;

    if (lists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Henüz liste yok. Önce Listelerim sekmesinden bir liste oluşturun.'),
        ),
      );
      return;
    }

    final result = await showModalBottomSheet<(ProductList, String)>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ListPickerSheet(lists: lists, productName: widget.product.stockname),
    );
    if (result == null || !mounted) return;
    final (selected, note) = result;

    try {
      await _repo.addListItem(selected.id, widget.product.barcode, note: note);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${selected.name}" listesine eklendi.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Eklenemedi, tekrar deneyin.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _busy ? null : _openPicker,
        style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800),
        child: _busy
            ? const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Text('Listeye Ekle'),
      ),
    );
  }
}

class _ListPickerSheet extends StatefulWidget {
  final List<ProductList> lists;
  final String productName;

  const _ListPickerSheet({required this.lists, required this.productName});

  @override
  State<_ListPickerSheet> createState() => _ListPickerSheetState();
}

class _ListPickerSheetState extends State<_ListPickerSheet> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Listeye Ekle', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
                    const SizedBox(height: 2),
                    Text(widget.productName, style: const TextStyle(color: AppColors.brown500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _noteController,
                  decoration: const InputDecoration(labelText: 'Not (opsiyonel)', isDense: true),
                  maxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: widget.lists.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final l = widget.lists[i];
                    return ListTile(
                      title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown900)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: l.type.accentColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          l.type.label,
                          style: TextStyle(color: l.type.accentColor, fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop((l, _noteController.text.trim())),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
