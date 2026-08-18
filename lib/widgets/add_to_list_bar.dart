import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

/// List picker + "Listeye Ekle" button, shared by the scanner and search
/// screens. Loads the list of lists itself so callers don't have to thread
/// that state through.
class AddToListBar extends StatefulWidget {
  final Product product;

  const AddToListBar({super.key, required this.product});

  @override
  State<AddToListBar> createState() => _AddToListBarState();
}

class _AddToListBarState extends State<AddToListBar> {
  final _repo = DataRepo();
  late Future<List<ProductList>> _listsFuture;
  String? _selectedListId;
  bool _adding = false;
  bool _added = false;

  @override
  void initState() {
    super.initState();
    _listsFuture = _repo.getLists();
  }

  @override
  void didUpdateWidget(covariant AddToListBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product.barcode != widget.product.barcode) {
      setState(() => _added = false);
    }
  }

  Future<void> _add() async {
    if (_selectedListId == null) return;
    setState(() => _adding = true);
    try {
      await _repo.addListItem(_selectedListId!, widget.product.barcode);
      if (mounted) setState(() => _added = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Eklenemedi, tekrar deneyin.')),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ProductList>>(
      future: _listsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(height: 40, child: Center(child: CircularProgressIndicator()));
        }
        final lists = snapshot.data!;
        if (lists.isEmpty) {
          return const Text(
            'Henüz liste yok. Önce Listelerim sekmesinden bir liste oluşturun.',
            style: TextStyle(color: AppColors.brown500, fontSize: 13),
          );
        }
        _selectedListId ??= lists.first.id;

        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _selectedListId,
                items: lists
                    .map((l) => DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (v) => setState(() {
                  _selectedListId = v;
                  _added = false;
                }),
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _adding ? null : _add,
              style: ElevatedButton.styleFrom(
                backgroundColor: _added ? AppColors.olive : AppColors.brown800,
              ),
              child: _adding
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(_added ? 'Eklendi ✓' : 'Listeye Ekle'),
            ),
          ],
        );
      },
    );
  }
}
