import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../excel_import.dart';
import '../format.dart';
import '../models.dart';
import '../pdf_import.dart';
import '../theme.dart';

enum _RowStatus { update, newProduct, invalidBarcode, missingPrice }

class _ReviewRow {
  final ImportRow raw;
  final Product? existing;
  final _RowStatus status;

  const _ReviewRow({required this.raw, required this.existing, required this.status});
}

/// Bulk price-raise import from a supplier's Excel or PDF file -- matches
/// rows by barcode against what we already have, stages price changes
/// exactly the way any other edit is staged (so they land in Kasaya
/// Gönder, never sent directly -- see kasaya_gonder_screen.dart's doc
/// comment on why all real price changes go through that one review
/// step), and optionally creates brand-new products for barcodes we don't
/// recognize yet. No LLM involved anywhere -- column meaning is a
/// heuristic guess (see price_list_grid.dart, fed either by
/// excel_import.dart or pdf_import.dart depending on the file picked)
/// that a human always confirms or corrects on this screen before
/// anything is staged or created.
class BulkPriceImportScreen extends StatefulWidget {
  const BulkPriceImportScreen({super.key});

  @override
  State<BulkPriceImportScreen> createState() => _BulkPriceImportScreenState();
}

class _BulkPriceImportScreenState extends State<BulkPriceImportScreen> {
  final _repo = DataRepo();
  bool _loading = false;
  String? _error;
  String? _fileName;

  List<List<String>> _rows = [];
  int _dataStartRow = 0;
  int? _barcodeCol;
  int? _nameCol;
  int? _priceCol;
  int? _kdvCol;
  String? _pdfDropNote;

  List<KdvDepartment> _departments = [];
  List<_ReviewRow> _reviewRows = [];
  final Set<int> _selected = {};
  bool _createMissing = false;
  bool _submitting = false;
  int? _submitTotal;
  int _submitDone = 0;

  @override
  void initState() {
    super.initState();
    _repo.getKdvDepartments().then((d) {
      if (mounted) setState(() => _departments = d);
    }).catchError((_) {});
  }

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'pdf']);
      if (files.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final picked = files.single;
      final bytes = await picked.readAsBytes();
      final isPdf = picked.name.toLowerCase().endsWith('.pdf');

      List<List<String>> grid;
      String? dropNote;
      if (isPdf) {
        final result = gridFromPdfBytes(bytes);
        grid = result.grid;
        if (result.totalRows == 0) {
          throw Exception('PDF\'de metin bulunamadı -- taranmış/fotoğraf bir PDF ise bu yöntem çalışmaz.');
        }
        final dropped = result.totalRows - result.keptRows;
        if (dropped > 0) {
          dropNote = 'PDF\'deki $dropped satır düzensiz göründüğü için atlandı (toplam ${result.totalRows} satırdan ${result.keptRows} tanesi okundu).';
        }
      } else {
        final excel = Excel.decodeBytes(bytes);
        if (excel.tables.isEmpty) throw Exception('Dosyada sayfa bulunamadı.');
        final sheet = excel.tables[excel.tables.keys.first]!;
        grid = gridFromExcelRows(sheet.rows);
      }

      final guess = detectColumns(grid);
      setState(() {
        _fileName = picked.name;
        _rows = grid;
        _pdfDropNote = dropNote;
        _dataStartRow = guess.dataStartRow;
        _barcodeCol = guess.barcodeCol;
        _nameCol = guess.nameCol;
        _priceCol = guess.priceCol;
        _kdvCol = guess.kdvCol;
      });
      await _reparse();
    } catch (e) {
      setState(() => _error = 'Dosya okunamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reparse() async {
    if (_barcodeCol == null || _rows.isEmpty) {
      setState(() {
        _reviewRows = [];
        _selected.clear();
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final parsed = parseRows(
        _rows,
        dataStartRow: _dataStartRow,
        barcodeCol: _barcodeCol,
        nameCol: _nameCol,
        priceCol: _priceCol,
        kdvCol: _kdvCol,
      );
      final matched = await _repo.lookupProductsLocal(parsed.map((r) => r.barcode).toList());
      final reviewed = <_ReviewRow>[];
      for (final r in parsed) {
        final existing = matched[r.barcode];
        final _RowStatus status;
        if (!isPlausibleBarcode(r.barcode) || !isValidEan13(r.barcode)) {
          status = _RowStatus.invalidBarcode;
        } else if (r.price == null) {
          status = _RowStatus.missingPrice;
        } else if (existing != null) {
          status = _RowStatus.update;
        } else {
          status = _RowStatus.newProduct;
        }
        reviewed.add(_ReviewRow(raw: r, existing: existing, status: status));
      }
      if (!mounted) return;
      setState(() {
        _reviewRows = reviewed;
        _selected
          ..clear()
          ..addAll([
            for (var i = 0; i < reviewed.length; i++)
              if (reviewed[i].status == _RowStatus.update ||
                  (_createMissing && reviewed[i].status == _RowStatus.newProduct && reviewed[i].raw.name != null))
                i,
          ]);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setCreateMissing(bool value) {
    setState(() {
      _createMissing = value;
      for (var i = 0; i < _reviewRows.length; i++) {
        final row = _reviewRows[i];
        if (row.status != _RowStatus.newProduct || row.raw.name == null) continue;
        if (value) {
          _selected.add(i);
        } else {
          _selected.remove(i);
        }
      }
    });
  }

  Future<void> _submit() async {
    final rowsToSend = _selected.toList()..sort();
    if (rowsToSend.isEmpty) return;
    setState(() {
      _submitting = true;
      _submitTotal = rowsToSend.length;
      _submitDone = 0;
    });
    var updated = 0;
    var created = 0;
    var failed = 0;
    for (final i in rowsToSend) {
      final row = _reviewRows[i];
      try {
        if (row.status == _RowStatus.update) {
          await _repo.stageChange(barcode: row.raw.barcode, field: 'price', value: row.raw.price!.toString());
          updated++;
        } else if (row.status == _RowStatus.newProduct) {
          final dept = matchKdvDepartmentByRate(row.raw.kdvRate, _departments);
          await _repo.stageProductCreate(
            barcode: row.raw.barcode,
            stockname: row.raw.name!,
            price: row.raw.price!,
            kasadepid: dept?.kasadepid,
            kdvRate: row.raw.kdvRate,
          );
          created++;
        }
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => _submitDone++);
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('İçe Aktarma Tamamlandı'),
        content: Text(
          [
            if (updated > 0) '$updated fiyat değişikliği Kasaya Gönder\'e eklendi.',
            if (created > 0) '$created yeni ürün Kasaya Gönder\'e eklendi.',
            if (failed > 0) '$failed satır başarısız oldu.',
          ].join('\n'),
        ),
        actions: [
          ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam')),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fiyat Listesi İçe Aktar')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFilePickRow(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: AppColors.terracotta)),
              ],
              if (_pdfDropNote != null) ...[
                const SizedBox(height: 8),
                Text(_pdfDropNote!, style: const TextStyle(color: AppColors.mustard, fontSize: 12)),
              ],
              if (_rows.isNotEmpty) ...[
                const SizedBox(height: 14),
                _buildColumnMapping(),
                const SizedBox(height: 14),
                _buildCreateMissingToggle(),
                const SizedBox(height: 10),
                Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : _buildReviewTable()),
                const SizedBox(height: 12),
                _buildSubmitBar(),
              ] else if (!_loading)
                const Expanded(
                  child: Center(
                    child: Text(
                      'Tedarikçiden gelen fiyat listesi dosyasını seçin (.xlsx veya .pdf).',
                      style: TextStyle(color: AppColors.brown400),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else
                const Expanded(child: Center(child: CircularProgressIndicator())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilePickRow() {
    return Row(
      children: [
        ElevatedButton.icon(
          onPressed: _loading ? null : _pickFile,
          icon: const Icon(Icons.upload_file, size: 18),
          label: Text(_fileName == null ? 'Excel veya PDF Dosyası Seç' : 'Farklı Dosya Seç'),
        ),
        if (_fileName != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(_fileName!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.brown600)),
          ),
        ],
      ],
    );
  }

  Widget _colDropdown({
    required String label,
    required int? value,
    required bool required,
    required ValueChanged<int?> onChanged,
  }) {
    var colCount = 0;
    for (final r in _rows) {
      if (r.length > colCount) colCount = r.length;
    }
    return SizedBox(
      width: 220,
      child: DropdownButtonFormField<int?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: required ? '$label *' : label, isDense: true),
        items: [
          if (!required) const DropdownMenuItem(value: null, child: Text('Yok')),
          for (var c = 0; c < colCount; c++)
            DropdownMenuItem(
              value: c,
              child: Text(
                // headerRowIndex is exactly dataStartRow - 1 in both cases
                // (including the "no header" sentinel, -1, when
                // dataStartRow is 0) -- see detectColumns in excel_import.dart.
                columnLabel(_rows, _dataStartRow - 1, c),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildColumnMapping() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.brown100, borderRadius: BorderRadius.circular(AppRadius.box)),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _colDropdown(
            label: 'Barkod Sütunu',
            value: _barcodeCol,
            required: true,
            onChanged: (v) {
              setState(() => _barcodeCol = v);
              _reparse();
            },
          ),
          _colDropdown(
            label: 'Ürün Adı Sütunu',
            value: _nameCol,
            required: false,
            onChanged: (v) {
              setState(() => _nameCol = v);
              _reparse();
            },
          ),
          _colDropdown(
            label: 'Fiyat Sütunu',
            value: _priceCol,
            required: true,
            onChanged: (v) {
              setState(() => _priceCol = v);
              _reparse();
            },
          ),
          _colDropdown(
            label: 'KDV Sütunu',
            value: _kdvCol,
            required: false,
            onChanged: (v) {
              setState(() => _kdvCol = v);
              _reparse();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCreateMissingToggle() {
    final missingCount = _reviewRows.where((r) => r.status == _RowStatus.newProduct).length;
    return SwitchListTile(
      value: _createMissing,
      onChanged: missingCount == 0 ? null : _setCreateMissing,
      activeThumbColor: AppColors.terracotta,
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Bulunmayan $missingCount ürünü de yeni ürün olarak oluştur',
        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown800, fontSize: 13),
      ),
      subtitle: const Text('Adı ve fiyatı dosyada olmayan satırlar otomatik atlanır.', style: TextStyle(fontSize: 12)),
    );
  }

  Widget _buildReviewTable() {
    if (_reviewRows.isEmpty) {
      return const Center(child: Text('Satır bulunamadı -- barkod sütununu kontrol edin.', style: TextStyle(color: AppColors.brown500)));
    }
    return Container(
      decoration: BoxDecoration(border: Border.all(color: AppColors.creamBorder), borderRadius: BorderRadius.circular(AppRadius.box)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: AppColors.brown100,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: const Row(
              children: [
                SizedBox(width: 32),
                Expanded(flex: 3, child: Text('Ürün', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                SizedBox(width: 150, child: Text('Barkod', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                SizedBox(width: 90, child: Text('Mevcut ₺', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                SizedBox(width: 90, child: Text('Yeni ₺', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                SizedBox(width: 130, child: Text('Durum', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _reviewRows.length,
              itemBuilder: (context, i) => _buildReviewRow(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewRow(int i) {
    final row = _reviewRows[i];
    final selectable = row.status == _RowStatus.update || (row.status == _RowStatus.newProduct && row.raw.name != null);
    final selected = _selected.contains(i);
    final (label, color) = switch (row.status) {
      _RowStatus.update => ('Fiyat Güncellenecek', AppColors.brown700),
      _RowStatus.newProduct => (row.raw.name != null ? 'Yeni Ürün' : 'Yeni Ürün (isim eksik)', AppColors.terracotta),
      _RowStatus.invalidBarcode => ('Geçersiz Barkod', Colors.red),
      _RowStatus.missingPrice => ('Fiyat Yok', Colors.red),
    };
    return Container(
      decoration: BoxDecoration(
        color: row.status == _RowStatus.invalidBarcode || row.status == _RowStatus.missingPrice
            ? Colors.red.withValues(alpha: 0.06)
            : (i.isEven ? Colors.white : AppColors.creamCard),
        border: const Border(bottom: BorderSide(color: AppColors.creamBorder, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Checkbox(
              value: selected,
              onChanged: !selectable
                  ? null
                  : (_) => setState(() {
                        if (selected) {
                          _selected.remove(i);
                        } else {
                          _selected.add(i);
                        }
                      }),
              activeColor: AppColors.terracotta,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              row.existing?.stockname ?? row.raw.name ?? '-',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: AppColors.brown900),
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(row.raw.barcode, style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppColors.brown700)),
          ),
          SizedBox(width: 90, child: Text(formatPrice(row.existing?.price), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
          SizedBox(
            width: 90,
            child: Text(
              formatPrice(row.raw.price),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.brown900),
            ),
          ),
          SizedBox(
            width: 130,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(AppRadius.chip)),
              child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitBar() {
    if (_submitting) {
      return LinearProgressIndicator(value: _submitTotal == null || _submitTotal == 0 ? null : _submitDone / _submitTotal!);
    }
    return ElevatedButton.icon(
      onPressed: _selected.isEmpty ? null : _submit,
      style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800, padding: const EdgeInsets.symmetric(vertical: 14)),
      icon: const Icon(Icons.send_outlined, size: 18),
      label: Text('${_selected.length} Satırı İçe Aktar'),
    );
  }
}
