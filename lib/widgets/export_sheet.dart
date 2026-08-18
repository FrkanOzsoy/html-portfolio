import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../export.dart';
import '../models.dart';
import '../theme.dart';

/// Bottom sheet for exporting a list: pick which columns to include, then
/// pick a format -- Excel file, CSV file, or a plain-text copy to clipboard
/// (tab-separated, so it also pastes cleanly into a spreadsheet).
Future<void> showExportSheet(
  BuildContext context, {
  required ProductList list,
  required List<ListItem> items,
}) {
  final columns = exportColumnsFor(list);
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ExportSheet(list: list, items: items, columns: columns),
  );
}

class _ExportSheet extends StatefulWidget {
  final ProductList list;
  final List<ListItem> items;
  final List<ExportColumn> columns;

  const _ExportSheet({required this.list, required this.items, required this.columns});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late final Set<String> _selectedKeys = widget.columns.map((c) => c.key).toSet();
  bool _busy = false;

  List<ExportColumn> get _activeColumns =>
      widget.columns.where((c) => _selectedKeys.contains(c.key)).toList();

  String get _safeFileName =>
      widget.list.name.replaceAll(RegExp(r'[^a-z0-9ığüşöç ]', caseSensitive: false), '_');

  Future<void> _shareBytes(List<int> bytes, String extension, String mimeType) async {
    setState(() => _busy = true);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$_safeFileName.$extension');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: mimeType)], text: widget.list.name),
      );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv() async {
    final csv = buildCsv(_activeColumns, widget.items);
    await _shareBytes(utf8.encode(csv), 'csv', 'text/csv');
  }

  Future<void> _exportXlsx() async {
    final bytes = buildXlsxBytes(widget.list.name, _activeColumns, widget.items);
    await _shareBytes(
      bytes,
      'xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  Future<void> _copyToClipboard() async {
    final text = buildPlainText(_activeColumns, widget.items);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Panoya kopyalandı.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final noColumnsSelected = _selectedKeys.isEmpty;
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Dışa Aktar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('İçerecek bilgileri seçin', style: TextStyle(color: AppColors.brown500, fontSize: 13)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final c in widget.columns)
                    CheckboxListTile(
                      value: _selectedKeys.contains(c.key),
                      title: Text(c.label, style: const TextStyle(color: AppColors.brown800)),
                      activeColor: AppColors.terracotta,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _selectedKeys.add(c.key);
                        } else {
                          _selectedKeys.remove(c.key);
                        }
                      }),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (noColumnsSelected)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'En az bir bilgi seçin.',
                        style: TextStyle(color: AppColors.terracotta, fontSize: 12),
                      ),
                    ),
                  ElevatedButton.icon(
                    onPressed: _busy || noColumnsSelected ? null : _exportXlsx,
                    icon: const Icon(Icons.grid_on, size: 18),
                    label: const Text('Excel (.xlsx)'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _busy || noColumnsSelected ? null : _exportCsv,
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('CSV (.csv)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy || noColumnsSelected ? null : _copyToClipboard,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.brown300, width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.copy_all_outlined, size: 18, color: AppColors.brown700),
                    label: const Text('Panoya Kopyala (Metin)', style: TextStyle(color: AppColors.brown700)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
