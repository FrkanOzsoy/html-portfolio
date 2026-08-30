import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../theme.dart';

/// A one-line pager bar for the big product tables (Ürün Ara, Ürün Satışları).
/// The caller keeps it *outside* the scrolling body so it stays put while the
/// rows scroll. Page size is the app-wide, persisted [appSettings.tablePageSize]
/// -- the dropdown here writes straight to it.
///
/// [pageIndex] is 0-based. The caller only shows this once [totalItems] is
/// bigger than [pageSize]; below that there's nothing to page through.
class TablePager extends StatelessWidget {
  final int totalItems;
  final int pageIndex;
  final int pageSize;
  final ValueChanged<int> onPageChanged;

  /// Fired after the page size changed (already persisted via appSettings) so
  /// the parent can reset its page index / scroll position.
  final ValueChanged<int> onPageSizeChanged;

  const TablePager({
    super.key,
    required this.totalItems,
    required this.pageIndex,
    required this.pageSize,
    required this.onPageChanged,
    required this.onPageSizeChanged,
  });

  int get _pageCount => totalItems <= 0 ? 1 : ((totalItems + pageSize - 1) ~/ pageSize);

  // First, last, and the current page ± 1 -- the rest collapse to an ellipsis.
  List<int> _pageNumbers(int current, int count) {
    return <int>{0, count - 1, current - 1, current, current + 1}.where((n) => n >= 0 && n < count).toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final count = _pageCount;
    final current = pageIndex.clamp(0, count - 1);
    final from = totalItems == 0 ? 0 : current * pageSize + 1;
    final to = ((current + 1) * pageSize).clamp(0, totalItems);
    final sizeOptions = {...AppSettingsController.tablePageSizeOptions, pageSize}.toList()..sort();

    final numberRow = <Widget>[];
    int? prev;
    for (final n in _pageNumbers(current, count)) {
      if (prev != null && n - prev > 1) {
        numberRow.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2),
          child: Text('…', style: TextStyle(color: AppColors.brown400, fontWeight: FontWeight.w700)),
        ));
      }
      numberRow.add(_PageChip(
        label: '${n + 1}',
        selected: n == current,
        onTap: n == current ? null : () => onPageChanged(n),
      ));
      prev = n;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.brown100,
        border: Border.all(color: AppColors.creamBorder),
        borderRadius: BorderRadius.circular(AppRadius.box),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Sayfa boyutu:',
                  style: TextStyle(fontSize: 12, color: AppColors.brown600, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: pageSize,
                  isDense: true,
                  iconSize: 18,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.brown900, fontWeight: FontWeight.w700),
                  items: [for (final n in sizeOptions) DropdownMenuItem(value: n, child: Text('$n'))],
                  onChanged: (v) async {
                    if (v == null || v == pageSize) return;
                    await appSettings.setTablePageSize(v);
                    onPageSizeChanged(v);
                  },
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NavArrow(icon: Icons.chevron_left, onTap: current > 0 ? () => onPageChanged(current - 1) : null),
              const SizedBox(width: 2),
              ...numberRow,
              const SizedBox(width: 2),
              _NavArrow(
                  icon: Icons.chevron_right, onTap: current < count - 1 ? () => onPageChanged(current + 1) : null),
            ],
          ),
          Text('$from–$to / $totalItems',
              style: const TextStyle(fontSize: 11.5, color: AppColors.brown500, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PageChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _PageChip({required this.label, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        constraints: const BoxConstraints(minWidth: 26),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.terracotta : AppColors.creamCard,
          border: Border.all(color: selected ? AppColors.terracotta : AppColors.creamBorder),
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: selected ? Colors.white : AppColors.brown700),
        ),
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _NavArrow({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(icon, size: 20, color: onTap == null ? AppColors.brown300 : AppColors.brown700),
      ),
    );
  }
}
