import 'package:excel/excel.dart' hide Border;

export 'price_list_grid.dart';

/// Excel-specific half of the bulk price-list import -- turns a sheet's
/// cells into the plain `List<List<String>>` grid that price_list_grid.dart
/// (the shared, format-agnostic heuristic) actually works on. See
/// pdf_import.dart for the PDF equivalent of this adapter.

String _cellText(Data? cell) {
  final v = cell?.value;
  if (v == null) return '';
  if (v is TextCellValue) return v.value.toString().trim();
  if (v is IntCellValue) return v.value.toString();
  if (v is DoubleCellValue) return v.value.toString();
  if (v is DateCellValue) return v.asDateTimeLocal().toIso8601String();
  return v.toString().trim();
}

List<List<String>> gridFromExcelRows(List<List<Data?>> rows) {
  return [for (final row in rows) [for (final cell in row) _cellText(cell)]];
}
