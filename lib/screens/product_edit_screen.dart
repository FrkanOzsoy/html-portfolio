import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/server_action_button.dart';

/// Propose a new price/name/department for a product from "Ürün Ara", a
/// list item, or the scanner. Saving only stages the change (via
/// `product_pending_changes`) -- it never reaches Digisoft/kasa on its own.
/// Review, select, and actually send staged changes from the "Kasaya
/// Gönder" tab. One "Kaydet" commits whichever fields were actually
/// touched, rather than each field having its own save button.
class ProductEditScreen extends StatefulWidget {
  final Product product;
  /// Set when opened from a list item's "Düzenle" button so staged changes
  /// still group under that list's name on the "Kasaya Gönder" tab -- purely
  /// contextual metadata, this is still the exact same editor as "Ürün Ara".
  final String? sourceListId;
  final String? sourceListName;

  const ProductEditScreen({super.key, required this.product, this.sourceListId, this.sourceListName});

  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  final _repo = DataRepo();
  late final TextEditingController _priceController;
  late final TextEditingController _nameController;
  late final Future<List<KdvDepartment>> _departmentsFuture = _repo.getKdvDepartments();
  int? _selectedDepartment;
  String? _priceError;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _priceController = TextEditingController(text: p.price?.toString() ?? '');
    _nameController = TextEditingController(text: p.stockname);
    _loadStaged();
  }

  // Pre-fills from whatever's already staged (from a previous visit, or
  // staged by someone else on another device), so reopening this screen
  // shows the pending values rather than silently reverting to Digisoft's.
  // If nothing's staged for the KDV department, falls back to whichever
  // department matches the product's own synced kdv_rate (see
  // matchKdvDepartmentByRate) so the dropdown opens on the product's
  // actual current KDV instead of blank.
  Future<void> _loadStaged() async {
    final changes = await _repo.getPendingChangesForBarcode(widget.product.barcode);
    for (final c in changes) {
      switch (c.field) {
        case 'price':
          _priceController.text = c.newValue;
        case 'stockname':
          _nameController.text = c.newValue;
        case 'kasadepid':
          _selectedDepartment = int.tryParse(c.newValue);
      }
    }
    if (_selectedDepartment == null) {
      final departments = await _departmentsFuture;
      final match = matchKdvDepartmentByRate(widget.product.kdvRate, departments);
      if (match != null) _selectedDepartment = match.kasadepid;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _priceController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<bool> _saveAll() async {
    final p = widget.product;
    final priceText = _priceController.text.trim().replaceAll(',', '.');
    final priceValue = num.tryParse(priceText);
    if (priceValue == null || priceValue <= 0) {
      setState(() => _priceError = 'Geçerli bir fiyat girin.');
      return false;
    }
    setState(() => _priceError = null);

    if (priceValue != p.price) {
      await _repo.stageChange(
        barcode: p.barcode,
        field: 'price',
        value: priceText,
        listId: widget.sourceListId,
        listName: widget.sourceListName,
      );
    }
    final nameValue = _nameController.text.trim();
    if (nameValue.isNotEmpty && nameValue != p.stockname) {
      await _repo.stageChange(
        barcode: p.barcode,
        field: 'stockname',
        value: nameValue,
        listId: widget.sourceListId,
        listName: widget.sourceListName,
      );
    }
    final dept = _selectedDepartment;
    if (dept != null) {
      await _repo.stageChange(
        barcode: p.barcode,
        field: 'kasadepid',
        value: dept.toString(),
        listId: widget.sourceListId,
        listName: widget.sourceListName,
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ürünü Düzenle'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _DeleteProductButton(barcode: p.barcode, stockname: p.stockname)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                p.barcode,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brown600),
              ),
              if (p.kdvRate != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Mevcut KDV: %${p.kdvRate!.toStringAsFixed(p.kdvRate! % 1 == 0 ? 0 : 2)}',
                  style: const TextStyle(fontSize: 13, color: AppColors.brown500),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Fiyat (₺)', isDense: true, errorText: _priceError),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Ürün Adı', isDense: true),
              ),
              const SizedBox(height: 16),
              FutureBuilder<List<KdvDepartment>>(
                future: _departmentsFuture,
                builder: (context, snapshot) {
                  final departments = snapshot.data ?? [];
                  return DropdownButtonFormField<int>(
                    initialValue: _selectedDepartment,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'KDV', isDense: true),
                    hint: Text(
                      snapshot.connectionState == ConnectionState.waiting ? 'Yükleniyor…' : 'KDV seçin',
                    ),
                    items: [
                      for (final d in departments)
                        DropdownMenuItem(value: d.kasadepid, child: Text(d.displayLabel, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _selectedDepartment = v),
                  );
                },
              ),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 160,
                  child: ServerActionButton(
                    icon: Icons.save_outlined,
                    label: 'Kaydet',
                    successLabel: 'Kaydedildi',
                    color: AppColors.brown800,
                    onPressed: _saveAll,
                    // Held long enough to actually register as "done" at a
                    // glance before the screen moves on.
                    onSuccess: () async {
                      await Future.delayed(const Duration(milliseconds: 900));
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              _LabelPrintSection(barcode: p.barcode),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact top-bar delete action -- confirm dialog first (no separate
/// reveal step needed since a dialog already gates the real send), then
/// fires the delete request and pops this screen once Digisoft confirms.
/// Solid terracotta fill + white text/icon, matching the rest of the app's
/// "filled = commit action" convention -- just terracotta instead of
/// brown800 since this one is destructive.
class _DeleteProductButton extends StatefulWidget {
  final String barcode;
  final String stockname;

  const _DeleteProductButton({required this.barcode, required this.stockname});

  @override
  State<_DeleteProductButton> createState() => _DeleteProductButtonState();
}

class _DeleteProductButtonState extends State<_DeleteProductButton> {
  final _repo = DataRepo();
  bool _busy = false;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ürünü Sil'),
        content: Text(
          '"${widget.stockname}" ürününü silmek için Kasaya Gönder\'e bir silme isteği eklenecek. '
          'Ürün, oradan onaylanana kadar Digisoft\'tan silinmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kasaya Gönder\'e Ekle', style: TextStyle(color: AppColors.terracotta)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _repo.stageDelete(widget.barcode);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Silme isteği Kasaya Gönder\'e eklendi.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kaydedilemedi, tekrar deneyin.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.terracotta,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        onTap: _busy ? null : _confirmAndDelete,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline, size: 16, color: Colors.white),
                    SizedBox(width: 4),
                    Text('Sil', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Requests a print job on the Argox label printer physically attached to
/// the till PC -- an immediate live request, since printing isn't
/// something that benefits from batched review like the fields above.
/// See barkod-tarayici/TILL_PC_GOREVLERI.md for the till-PC side.
class _LabelPrintSection extends StatefulWidget {
  final String barcode;
  const _LabelPrintSection({required this.barcode});

  @override
  State<_LabelPrintSection> createState() => _LabelPrintSectionState();
}

class _LabelPrintSectionState extends State<_LabelPrintSection> {
  final _repo = DataRepo();
  int _quantity = 1;
  StreamSubscription? _sub;
  Timer? _timeoutTimer;
  String? _status;
  String? _errorMessage;

  @override
  void dispose() {
    _sub?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  bool get _busy => _status == 'pending' || _status == 'processing';

  Future<void> _print() async {
    _timeoutTimer?.cancel();
    setState(() {
      _status = 'pending';
      _errorMessage = null;
    });
    // If nothing at all comes back within 10s (till-PC service down, or the
    // request never reached it), stop spinning forever and tell staff to go
    // check the till themselves instead of leaving them guessing.
    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _busy) setState(() => _status = 'timeout');
    });
    try {
      final id = await _repo.requestLabelPrint(widget.barcode, _quantity);
      _sub?.cancel();
      _sub = _repo.watchLabelPrintStatus(id).listen((s) {
        if (!mounted) return;
        setState(() {
          _status = s.status;
          _errorMessage = s.errorMessage;
        });
        if (s.status == 'done' || s.status == 'error') _timeoutTimer?.cancel();
      });
    } catch (_) {
      _timeoutTimer?.cancel();
      if (mounted) {
        setState(() {
          _status = 'error';
          _errorMessage = 'İstek gönderilemedi (bağlantı yok olabilir).';
        });
      }
    }
  }

  Color get _statusColor => switch (_status) {
        'done' => AppColors.success,
        'error' || 'timeout' => AppColors.terracotta,
        'pending' || 'processing' => AppColors.mustard,
        _ => AppColors.brown400,
      };

  String get _statusText => switch (_status) {
        'pending' => 'Bekliyor…',
        'processing' => 'Yazdırılıyor…',
        'done' => 'Yazdırıldı ✓',
        'error' => _errorMessage ?? 'Hata oluştu',
        'timeout' => 'Yanıt alınamadı -- kasa bilgisayarını kendiniz kontrol edin.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Etiket Yazdır', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.brown800)),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: AppColors.brown600),
              onPressed: _busy || _quantity <= 1 ? null : () => setState(() => _quantity--),
            ),
            Text('$_quantity', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: AppColors.brown600),
              onPressed: _busy || _quantity >= 50 ? null : () => setState(() => _quantity++),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _print,
                icon: _busy
                    ? const SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.print_outlined, size: 18),
                label: const Text('Yazdır'),
              ),
            ),
          ],
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(_statusText, style: TextStyle(color: _statusColor, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}
