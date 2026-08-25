import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../theme.dart';
import 'server_action_button.dart';

/// One-tap single-label print, surfaced everywhere a product already shows
/// on screen (scanner, search, list items) so staff don't have to open the
/// full editor just to print one copy. Reuses the same squeeze/pop
/// green-or-red [ServerActionButton] as every other commit action in the
/// app -- the editor's own print section (product_edit_screen.dart) still
/// exists separately for choosing a quantity or reprinting.
class PrintLabelButton extends StatelessWidget {
  final String barcode;
  const PrintLabelButton({super.key, required this.barcode});

  Future<bool> _print() async {
    final repo = DataRepo();
    try {
      final id = await repo.requestLabelPrint(barcode, 1);
      final result = await repo
          .watchLabelPrintStatus(id)
          .firstWhere(
            (s) => s.status == 'done' || s.status == 'error',
            orElse: () => (status: 'error', errorMessage: null),
          )
          .timeout(const Duration(seconds: 12), onTimeout: () => (status: 'error', errorMessage: null));
      return result.status == 'done';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ServerActionButton(
      icon: Icons.print_outlined,
      label: 'Etiket',
      successLabel: 'Yazdırıldı',
      color: AppColors.brown800,
      onPressed: _print,
    );
  }
}
