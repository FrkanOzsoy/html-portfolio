import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import 'add_to_list_button.dart';
import 'edit_product_button.dart';

/// Shared: open a product in a small sheet with the standard edit / add-to-list
/// actions (used from Ölü Stok, the top-products table, the mismatch table,
/// and the Ürün Satışları / Kasap sales tables).
///
/// When [voidBreakdown] is supplied (Ürün Satışları / Kasap only -- those are
/// the two callers with a date range in scope), the sheet also renders a
/// "sold vs. iptal" split for that barcode over that range, once it resolves.
Future<void> peekProduct(
  BuildContext context,
  String barcode, {
  Future<SalesVoidBreakdown>? voidBreakdown,
}) async {
  final repo = DataRepo();
  final product = await repo.lookupBarcode(barcode);
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(product?.stockname ?? 'Ürün bulunamadı',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AppColors.brown900)),
          const SizedBox(height: 4),
          Text('$barcode${product?.price != null ? '  ·  ${formatPrice(product!.price)}' : ''}',
              style: const TextStyle(color: AppColors.brown500, fontSize: 13)),
          const SizedBox(height: 16),
          if (product != null)
            Row(
              children: [
                Expanded(child: EditProductButton(product: product)),
                const SizedBox(width: 10),
                Expanded(child: AddToListButton(product: product)),
              ],
            ),
          if (voidBreakdown != null) ...[
            const SizedBox(height: 16),
            FutureBuilder<SalesVoidBreakdown>(
              future: voidBreakdown,
              builder: (context, snapshot) {
                final b = snapshot.data;
                if (b == null) {
                  return const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                return Text(
                  'Bu dönemde: ${b.soldCount} satıldı (${formatPrice(b.soldRevenue)})'
                  '${b.voidCount > 0 ? '  ·  ${b.voidCount} iptal edildi (${formatPrice(b.voidRevenue)})' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.brown600, fontWeight: FontWeight.w600),
                );
              },
            ),
          ],
        ],
      ),
    ),
  );
}
