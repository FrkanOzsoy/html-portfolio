import 'package:excel/excel.dart';
import 'format.dart';
import 'models.dart';

/// One exportable column: a stable [key] (used to remember which columns the
/// user picked), a Turkish [label] for the header/checkbox, and how to pull
/// the value out of a [ListItem].
class ExportColumn {
  final String key;
  final String label;
  final String Function(ListItem item) getValue;

  const ExportColumn({required this.key, required this.label, required this.getValue});
}

/// Which columns are available depends on the list type -- the same set the
/// UI already edits per type, plus the base product columns every list has.
List<ExportColumn> exportColumnsFor(ProductList list) {
  final columns = <ExportColumn>[
    ExportColumn(key: 'barcode', label: 'Barkod', getValue: (i) => i.barcode),
    ExportColumn(key: 'name', label: 'Ürün Adı', getValue: (i) => i.product?.stockname ?? ''),
    ExportColumn(key: 'price', label: 'Fiyat', getValue: (i) => formatPrice(i.product?.price)),
    ExportColumn(key: 'unit', label: 'Birim', getValue: (i) => i.product?.stockunit ?? ''),
  ];

  switch (list.type) {
    case ListKind.restock:
      columns.add(ExportColumn(key: 'quantity', label: 'Miktar', getValue: (i) => i.quantity?.toString() ?? ''));
    case ListKind.priceChange:
      columns.add(ExportColumn(key: 'new_price', label: 'Yeni Fiyat', getValue: (i) => formatPrice(i.newPrice)));
    case ListKind.priceCheck:
      columns.add(ExportColumn(key: 'note', label: 'Not', getValue: (i) => i.note ?? ''));
    case ListKind.custom:
      for (final f in list.fields) {
        columns.add(
          ExportColumn(key: 'custom_${f.key}', label: f.label, getValue: (i) => i.customData[f.key]?.toString() ?? ''),
        );
      }
  }
  return columns;
}

String _csvEscape(String s) {
  if (s.contains(RegExp(r'[",\n]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

String buildCsv(List<ExportColumn> columns, List<ListItem> items) {
  final lines = [
    columns.map((c) => _csvEscape(c.label)).join(','),
    for (final item in items) columns.map((c) => _csvEscape(c.getValue(item))).join(','),
  ];
  // UTF-8 BOM so Excel opens Turkish characters correctly.
  return '﻿${lines.join('\r\n')}';
}

/// "----" separates both the columns within one product and the products
/// from each other, so it reads cleanly when pasted into a chat app or notes
/// (no reliance on tab alignment surviving the paste).
String buildPlainText(List<ExportColumn> columns, List<ListItem> items) {
  final blocks = [
    for (final item in items)
      columns.map((c) => '${c.label}: ${c.getValue(item)}').join(' ---- '),
  ];
  return blocks.join('\n----\n');
}

List<int> buildXlsxBytes(String sheetName, List<ExportColumn> columns, List<ListItem> items) {
  final excel = Excel.createExcel();
  final defaultSheetName = excel.getDefaultSheet();
  final safeSheetName = sheetName.isEmpty ? 'Liste' : sheetName;
  excel[safeSheetName];
  if (defaultSheetName != null && defaultSheetName != safeSheetName) {
    excel.delete(defaultSheetName);
  }

  excel.appendRow(safeSheetName, columns.map((c) => TextCellValue(c.label)).toList());
  for (final item in items) {
    excel.appendRow(safeSheetName, columns.map((c) => TextCellValue(c.getValue(item))).toList());
  }

  return excel.encode()!;
}
