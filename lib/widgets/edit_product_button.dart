import 'package:flutter/material.dart';
import '../models.dart';
import '../theme.dart';
import '../screens/product_edit_screen.dart';

/// The one "Düzenle" entry point used everywhere a product's price/name can
/// be edited -- scanner, search, and list items all push this same
/// [ProductEditScreen] with this same look, so there is exactly one edit UI
/// in the app instead of several that could drift apart.
class EditProductButton extends StatelessWidget {
  final Product? product;
  /// Set when this button lives inside a list item, so staged changes still
  /// group under that list's name on the "Kasaya Gönder" tab.
  final String? sourceListId;
  final String? sourceListName;

  const EditProductButton({super.key, required this.product, this.sourceListId, this.sourceListName});

  @override
  Widget build(BuildContext context) {
    final p = product;
    return OutlinedButton.icon(
      onPressed: p == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProductEditScreen(
                    product: p,
                    sourceListId: sourceListId,
                    sourceListName: sourceListName,
                  ),
                ),
              ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.brown300, width: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
      ),
      icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.brown700),
      label: const FittedBox(
        fit: BoxFit.scaleDown,
        child: Text('Düzenle', style: TextStyle(color: AppColors.brown700)),
      ),
    );
  }
}
