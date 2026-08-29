import 'package:flutter/material.dart';
import '../theme.dart';

/// One column of a [SortableTable].
class SortColumn<T> {
  final String label;

  /// Fixed pixel width. Leave null to size by [flex] within the leftover space
  /// (wide layout) or [flex] * a base unit (narrow / horizontally-scrolled).
  final double? width;
  final int flex;

  /// Right-align header + cells (use for money / counts).
  final bool numeric;

  /// Value to sort this column by. Return a [Comparable] (num, String,
  /// DateTime). Nulls sort last regardless of direction.
  final Comparable<Object>? Function(T row) sortKey;

  /// The cell contents for [row].
  final Widget Function(T row) cell;

  const SortColumn({
    required this.label,
    required this.sortKey,
    required this.cell,
    this.width,
    this.flex = 1,
    this.numeric = false,
  });

  double get _scrollWidth => width ?? (flex * 108.0);
}

/// A compact data table where every column header is a click-to-sort control
/// (click again to reverse). Striped rows, optional row tap. When the columns
/// don't fit the available width (narrow phones), the whole table scrolls
/// horizontally instead of squeezing.
class SortableTable<T> extends StatefulWidget {
  final List<T> rows;
  final List<SortColumn<T>> columns;
  final int initialSortColumn;
  final bool initialAscending;
  final void Function(T row)? onRowTap;
  final String emptyText;

  /// Optional per-row background tint (e.g. flag voided rows).
  final Color? Function(T row)? rowTint;

  const SortableTable({
    super.key,
    required this.rows,
    required this.columns,
    this.initialSortColumn = 0,
    this.initialAscending = true,
    this.onRowTap,
    this.emptyText = 'Kayıt yok.',
    this.rowTint,
  });

  @override
  State<SortableTable<T>> createState() => _SortableTableState<T>();
}

class _SortableTableState<T> extends State<SortableTable<T>> {
  late int _sortCol = widget.initialSortColumn;
  late bool _asc = widget.initialAscending;

  void _toggle(int col) {
    setState(() {
      if (_sortCol == col) {
        _asc = !_asc;
      } else {
        _sortCol = col;
        _asc = !widget.columns[col].numeric; // text A→Z, numbers high→low first
      }
    });
  }

  List<T> get _sorted {
    final col = widget.columns[_sortCol];
    final rows = [...widget.rows];
    rows.sort((a, b) {
      final ka = col.sortKey(a);
      final kb = col.sortKey(b);
      if (ka == null && kb == null) return 0;
      if (ka == null) return 1; // nulls last
      if (kb == null) return -1;
      final c = ka.compareTo(kb);
      return _asc ? c : -c;
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(widget.emptyText, style: const TextStyle(color: AppColors.brown500)),
        ),
      );
    }

    final rows = _sorted;
    final scrollWidth = widget.columns.fold<double>(0, (s, c) => s + c._scrollWidth);

    return LayoutBuilder(
      builder: (context, c) {
        final fits = c.maxWidth >= scrollWidth || c.maxWidth == double.infinity;
        final table = Container(
          width: fits ? null : scrollWidth,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.creamBorder),
            borderRadius: BorderRadius.circular(AppRadius.box),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: AppColors.brown100,
                child: Row(children: [
                  for (var i = 0; i < widget.columns.length; i++) _header(i, fits),
                ]),
              ),
              for (var r = 0; r < rows.length; r++)
                _RowInk(
                  onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(rows[r]),
                  background: widget.rowTint?.call(rows[r]) ??
                      (r.isEven ? Colors.white : AppColors.creamCard),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (final col in widget.columns)
                        _wrap(
                          col,
                          fits,
                          Align(
                            alignment: col.numeric ? Alignment.centerRight : Alignment.centerLeft,
                            child: DefaultTextStyle.merge(
                              style: const TextStyle(fontSize: 12.5, color: AppColors.brown800),
                              child: col.cell(rows[r]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );

        if (fits) return table;
        return SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);
      },
    );
  }

  Widget _wrap(SortColumn<T> col, bool fits, Widget child) {
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: child,
    );
    if (!fits) return SizedBox(width: col._scrollWidth, child: padded);
    if (col.width != null) return SizedBox(width: col.width, child: padded);
    return Expanded(flex: col.flex, child: padded);
  }

  Widget _header(int i, bool fits) {
    final col = widget.columns[i];
    final active = _sortCol == i;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        mainAxisAlignment: col.numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              col.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: active ? AppColors.terracotta : AppColors.brown800,
              ),
            ),
          ),
          if (active)
            Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward, size: 13, color: AppColors.terracotta),
        ],
      ),
    );
    final tappable = InkWell(onTap: () => _toggle(i), child: content);
    if (!fits) return SizedBox(width: col._scrollWidth, child: tappable);
    if (col.width != null) return SizedBox(width: col.width, child: tappable);
    return Expanded(flex: col.flex, child: tappable);
  }
}

class _RowInk extends StatelessWidget {
  final Widget child;
  final Color background;
  final VoidCallback? onTap;
  const _RowInk({required this.child, required this.background, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: InkWell(onTap: onTap, child: child),
    );
  }
}
