import 'package:flutter/material.dart';
import '../format.dart';
import '../kasa_repo.dart';
import '../models.dart';
import '../theme.dart';
import 'product_peek_sheet.dart';
import 'sortable_table.dart';

String _qty(num? q) {
  if (q == null) return '-';
  return q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);
}

String _dmy(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

/// The product-sales-report table shared by "Ürün Satışları" and "Kasap" --
/// same columns, same row-tap-for-sold/iptal-breakdown behavior, over
/// whatever rows/date-range the caller already fetched via
/// KasaRepo.getProductSalesReport.
class ProductSalesReportTable extends StatelessWidget {
  final List<KasaProductSalesReport> rows;
  final int pageSize;
  final DateTime from;
  final DateTime to;
  final KasaRepo repo;

  const ProductSalesReportTable({
    super.key,
    required this.rows,
    required this.pageSize,
    required this.from,
    required this.to,
    required this.repo,
  });

  @override
  Widget build(BuildContext context) {
    return SortableTable<KasaProductSalesReport>(
      rows: rows,
      pageSize: pageSize,
      initialSortColumn: 4, // Ciro (revenue) desc
      initialAscending: false,
      emptyText: 'Seçili filtrelere uyan ürün kaydı bulunamadı.',
      onRowTap: (d) => peekProduct(
        context,
        d.barcode,
        voidBreakdown: repo.getSalesVoidBreakdown(barcode: d.barcode, from: from, to: to),
      ),
      columns: [
        SortColumn(
          label: 'Ürün',
          flex: 3,
          sortKey: (d) => d.stockname.toLowerCase(),
          cell: (d) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.stockname.isEmpty ? '-' : d.stockname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(d.barcode, style: const TextStyle(fontSize: 10.5, color: AppColors.brown400)),
            ],
          ),
        ),
        SortColumn(
          label: 'Fiyat',
          width: 88,
          numeric: true,
          sortKey: (d) => d.price ?? 0,
          cell: (d) => Text(formatPrice(d.price)),
        ),
        SortColumn(
          label: 'Reyon',
          width: 90,
          sortKey: (d) => (d.depno ?? '').toLowerCase(),
          cell: (d) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(d.depno ?? '-', style: const TextStyle(fontSize: 12, color: AppColors.brown700)),
              if (d.kdvRate != null)
                Text('%${d.kdvRate}', style: const TextStyle(fontSize: 10, color: AppColors.brown400)),
            ],
          ),
        ),
        SortColumn(
          label: 'Satılan Adet',
          width: 94,
          numeric: true,
          sortKey: (d) => d.qty,
          cell: (d) => Text(
            _qty(d.qty),
            style: TextStyle(
              fontWeight: d.qty > 0 ? FontWeight.w700 : FontWeight.normal,
              color: d.qty > 0 ? AppColors.brown900 : AppColors.brown400,
            ),
          ),
        ),
        SortColumn(
          label: 'Ciro',
          width: 100,
          numeric: true,
          sortKey: (d) => d.revenue,
          cell: (d) => Text(
            formatPrice(d.revenue),
            style: TextStyle(
              fontWeight: d.revenue > 0 ? FontWeight.w700 : FontWeight.normal,
              color: d.revenue > 0 ? AppColors.terracotta : AppColors.brown400,
            ),
          ),
        ),
        SortColumn(
          label: 'İşlem',
          width: 68,
          numeric: true,
          sortKey: (d) => d.lineCount,
          cell: (d) => Text(
            '${d.lineCount}',
            style: TextStyle(color: d.lineCount > 0 ? AppColors.brown700 : AppColors.brown400),
          ),
        ),
        SortColumn(
          label: 'Son Satış',
          width: 124,
          numeric: true,
          sortKey: (d) => d.lastSoldAt?.millisecondsSinceEpoch ?? 0,
          cell: (d) => Text(
            d.lastSoldAt == null ? 'hiç' : '${_dmy(d.lastSoldAt!)}${d.daysSince != null ? ' (${d.daysSince} g)' : ''}',
            style: const TextStyle(fontSize: 11.5, color: AppColors.brown600),
          ),
        ),
      ],
    );
  }
}
