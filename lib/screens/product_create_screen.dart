import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

/// Creates a brand-new product in Digisoft -- a live request (like label
/// printing), not staged like edits: there's no existing row to compare
/// against, so batching through "Gönder" wouldn't add anything here.
class ProductCreateScreen extends StatefulWidget {
  /// Pre-fills the barcode field -- set when reached from a "not found"
  /// scan/search result, so staff don't have to retype what was just typed.
  final String? initialBarcode;

  const ProductCreateScreen({super.key, this.initialBarcode});

  @override
  State<ProductCreateScreen> createState() => _ProductCreateScreenState();
}

class _ProductCreateScreenState extends State<ProductCreateScreen> {
  final _repo = DataRepo();
  final _formKey = GlobalKey<FormState>();
  late final _barcodeController = TextEditingController(text: widget.initialBarcode ?? '');
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _unitController = TextEditingController();
  late final Future<List<KdvDepartment>> _departmentsFuture = _repo.getKdvDepartments();
  int? _selectedDepartment;

  StreamSubscription? _sub;
  Timer? _timeoutTimer;
  String? _status;
  String? _errorMessage;

  bool get _busy => _status == 'pending' || _status == 'processing';

  @override
  void dispose() {
    _barcodeController.dispose();
    _nameController.dispose();
    _priceController.dispose();
    _unitController.dispose();
    _sub?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _submit(List<KdvDepartment> departments) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _timeoutTimer?.cancel();
    setState(() {
      _status = 'pending';
      _errorMessage = null;
    });
    // Same "don't spin forever" backstop as label printing -- if the
    // till-PC service is down, say so within 10s instead of hanging.
    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _busy) setState(() => _status = 'timeout');
    });
    try {
      KdvDepartment? dept;
      for (final d in departments) {
        if (d.kasadepid == _selectedDepartment) dept = d;
      }
      final id = await _repo.requestProductCreate(
        barcode: _barcodeController.text.trim(),
        stockname: _nameController.text.trim(),
        price: num.parse(_priceController.text.trim().replaceAll(',', '.')),
        kasadepid: dept?.kasadepid,
        kdvRate: dept?.kdvRate,
        stockunit: _unitController.text.trim().isEmpty ? null : _unitController.text.trim(),
      );
      _sub?.cancel();
      _sub = _repo.watchProductCreateStatus(id).listen((s) {
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
        'pending' => 'Gönderiliyor…',
        'processing' => 'Digisoft\'ta oluşturuluyor…',
        'done' => 'Ürün oluşturuldu ✓',
        'error' => _errorMessage ?? 'Hata oluştu',
        'timeout' => 'Yanıt alınamadı -- kasa bilgisayarını kendiniz kontrol edin.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yeni Ürün Oluştur')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<List<KdvDepartment>>(
            future: _departmentsFuture,
            builder: (context, snapshot) {
              final departments = snapshot.data ?? [];
              return Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _nameController,
                      enabled: !_busy,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Ürün Adı *'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Ürün adı gerekli.' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _barcodeController,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Barkod *'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Barkod gerekli.' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _priceController,
                      enabled: !_busy,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Fiyat (₺) *'),
                      validator: (v) {
                        final n = num.tryParse((v ?? '').trim().replaceAll(',', '.'));
                        if (n == null) return 'Geçerli bir sayı girin.';
                        if (n <= 0) return 'Fiyat 0\'dan büyük olmalı.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _unitController,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: 'Birim (örn. ADET, KG)'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: _selectedDepartment,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'KDV'),
                      hint: Text(
                        snapshot.connectionState == ConnectionState.waiting ? 'Yükleniyor…' : 'KDV seçin',
                      ),
                      items: [
                        for (final d in departments)
                          DropdownMenuItem(value: d.kasadepid, child: Text(d.displayLabel, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _busy ? null : (v) => setState(() => _selectedDepartment = v),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: _busy || !snapshot.hasData ? null : () => _submit(departments),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brown800,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: _busy
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.add_circle_outline, size: 18),
                      label: const Text('Ürünü Oluştur'),
                    ),
                    if (_status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_statusText, style: TextStyle(color: _statusColor, fontWeight: FontWeight.w600)),
                      ),
                    if (_status == 'done')
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.brown300, width: 2),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Kapat', style: TextStyle(color: AppColors.brown700)),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
