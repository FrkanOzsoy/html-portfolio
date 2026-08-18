import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/add_to_list_bar.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

sealed class _LookupState {}

class _Idle extends _LookupState {}

class _Loading extends _LookupState {
  final String barcode;
  _Loading(this.barcode);
}

class _Found extends _LookupState {
  final Product product;
  _Found(this.product);
}

class _NotFound extends _LookupState {
  final String barcode;
  _NotFound(this.barcode);
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _repo = DataRepo();
  final _controller = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  _LookupState _lookup = _Idle();
  String? _lastBarcode;
  DateTime? _lastScanAt;
  static const _rescanCooldown = Duration(seconds: 2);

  final _manualController = TextEditingController();
  Timer? _manualDebounce;
  List<Product> _manualResults = [];
  bool _manualLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    _manualController.dispose();
    _manualDebounce?.cancel();
    super.dispose();
  }

  Future<void> _handleScan(String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (barcode.isEmpty) return;

    final now = DateTime.now();
    if (_lastBarcode == barcode &&
        _lastScanAt != null &&
        now.difference(_lastScanAt!) < _rescanCooldown) {
      return;
    }
    _lastBarcode = barcode;
    _lastScanAt = now;

    setState(() => _lookup = _Loading(barcode));
    try {
      final product = await _repo.lookupBarcode(barcode);
      if (!mounted) return;
      setState(() => _lookup = product != null ? _Found(product) : _NotFound(barcode));
    } catch (_) {
      if (mounted) setState(() => _lookup = _NotFound(barcode));
    }
  }

  void _onManualQueryChanged(String value) {
    _manualDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _manualResults = [];
        _manualLoading = false;
      });
      return;
    }
    setState(() => _manualLoading = true);
    _manualDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final results = await _repo.searchProducts(value);
        if (mounted) setState(() => _manualResults = results);
      } finally {
        if (mounted) setState(() => _manualLoading = false);
      }
    });
  }

  void _pickManualResult(Product product) {
    _manualController.clear();
    setState(() => _manualResults = []);
    FocusScope.of(context).unfocus();
    _lastBarcode = null; // allow immediate re-selection even if just scanned
    _handleScan(product.barcode);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                TextField(
                  controller: _manualController,
                  onChanged: _onManualQueryChanged,
                  decoration: const InputDecoration(
                    hintText: 'Barkod veya ürün adı ile elle ara…',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                if (_manualController.text.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 52,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: _manualLoading
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('Aranıyor…'),
                              )
                            : _manualResults.isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text('Sonuç bulunamadı.'),
                                  )
                                : ListView.separated(
                                    shrinkWrap: true,
                                    itemCount: _manualResults.length,
                                    separatorBuilder: (_, _) => const Divider(height: 1),
                                    itemBuilder: (context, i) {
                                      final p = _manualResults[i];
                                      return ListTile(
                                        dense: true,
                                        title: Text(p.stockname, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        subtitle: Text('${p.barcode} · ${p.price ?? '-'} ₺'),
                                        onTap: () => _pickManualResult(p),
                                      );
                                    },
                                  ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 320,
                color: AppColors.brown950,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _controller,
                      onDetect: (capture) {
                        final value = capture.barcodes.firstOrNull?.rawValue;
                        if (value != null) _handleScan(value);
                      },
                    ),
                    Center(
                      child: Container(
                        width: 260,
                        height: 110,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: ValueListenableBuilder(
                        valueListenable: _controller,
                        builder: (context, state, child) {
                          if (!state.isInitialized || state.torchState == TorchState.unavailable) {
                            return const SizedBox.shrink();
                          }
                          final on = state.torchState == TorchState.on;
                          return CircleAvatar(
                            backgroundColor: on ? AppColors.terracotta : Colors.black45,
                            child: IconButton(
                              icon: Icon(on ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                              onPressed: () => _controller.toggleTorch(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Sadece çerçeve içindeki barkod okunur — ML Kit / Vision tabanlı yerel tarama.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.brown500, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(minHeight: 120),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.creamCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.creamBorder),
              ),
              child: _buildLookupContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLookupContent() {
    final state = _lookup;
    if (state is _Idle) {
      return const Text('Bir ürün tarayın, burada görünecek.', style: TextStyle(color: AppColors.brown400));
    }
    if (state is _Loading) {
      return Text('Aranıyor: ${state.barcode}…', style: const TextStyle(color: AppColors.brown500));
    }
    if (state is _NotFound) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Ürün bulunamadı', style: TextStyle(color: AppColors.terracotta, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Barkod: ${state.barcode}', style: const TextStyle(color: AppColors.brown500)),
        ],
      );
    }
    final product = (state as _Found).product;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          product.stockname,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AppColors.brown900),
        ),
        const SizedBox(height: 4),
        Text('Barkod: ${product.barcode}', style: const TextStyle(color: AppColors.brown500)),
        const SizedBox(height: 8),
        Row(
          children: [
            _pill('${product.price ?? '-'} ₺'),
            const SizedBox(width: 8),
            _pill(product.stockunit ?? '-'),
          ],
        ),
        const SizedBox(height: 12),
        AddToListBar(product: product),
      ],
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: AppColors.brown100, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(color: AppColors.brown800, fontWeight: FontWeight.w600)),
      );
}
