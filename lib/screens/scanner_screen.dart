import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../data_repo.dart';
import '../format.dart';
import '../models.dart';
import '../platform_util.dart';
import '../route_observer.dart';
import '../theme.dart';
import '../widgets/add_to_list_button.dart';
import '../widgets/edit_product_button.dart';
import '../widgets/print_label_button.dart';
import 'product_create_screen.dart';

class ScannerScreen extends StatefulWidget {
  /// Whether this is the currently-selected bottom-nav tab. home_shell.dart
  /// keeps every tab mounted via an IndexedStack (so state survives
  /// switching away and back), which means the camera would otherwise keep
  /// running -- capturing frames, holding the flash/camera hardware -- the
  /// entire time staff are on a completely different tab. Defaults to true
  /// so this screen still behaves normally if ever used outside HomeShell.
  final bool active;

  const ScannerScreen({super.key, this.active = true});

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

class _ScannerScreenState extends State<ScannerScreen> with RouteAware {
  final _repo = DataRepo();
  final _controller = MobileScannerController(
    autoStart: false,
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

  bool _cameraOn = false;
  _LookupState _lookup = _Idle();
  String? _lastBarcode;
  DateTime? _lastScanAt;
  static const _rescanCooldown = Duration(seconds: 2);

  @override
  void didUpdateWidget(ScannerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    // Same stop/restart-clean approach as didPushNext/didPopNext below,
    // just driven by the tab switch instead of a pushed route -- an
    // IndexedStack tab going offscreen fires neither of those, so without
    // this the camera would otherwise just keep running, unseen, on
    // whatever tab staff switched to.
    if (!widget.active) {
      if (_cameraOn) _controller.stop();
    } else {
      if (_cameraOn) _controller.start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _controller.dispose();
    super.dispose();
  }

  // This screen stays mounted at all times (home_shell.dart uses an
  // IndexedStack, not a lazy TabBarView), so pushing a full-screen route on
  // top -- e.g. "Düzenle" -- does not stop the camera on its own; it's left
  // running behind the new route. Some devices then hand back a stale/black
  // texture once that route pops and this screen is visible again. Stopping
  // the session while covered and cleanly restarting it once back on top
  // avoids that instead of trying to resume whatever state the platform
  // camera was left in.
  @override
  void didPushNext() {
    if (_cameraOn) _controller.stop();
  }

  @override
  void didPopNext() {
    if (_cameraOn) _controller.start();
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

  Future<void> _toggleCamera() async {
    if (_cameraOn) {
      await _controller.stop();
      if (mounted) setState(() => _cameraOn = false);
    } else {
      setState(() => _cameraOn = true);
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopPlatform;
    // Desktop has room to spare -- a 320px camera box floating at the top
    // of a 900px-tall window with a small text panel under it just reads
    // as empty. Side-by-side with a much bigger camera uses the space the
    // mobile stacked layout never had to begin with.
    final cameraHeight = desktop ? 640.0 : 320.0;
    final cameraBox = _buildCameraBox(cameraHeight);
    final lookupPanel = Container(
      constraints: BoxConstraints(minHeight: desktop ? cameraHeight : 120),
      padding: EdgeInsets.all(desktop ? 24 : 16),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: _buildLookupContent(desktop),
    );

    if (desktop) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: cameraBox),
              const SizedBox(width: 20),
              Expanded(flex: 2, child: lookupPanel),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            cameraBox,
            const SizedBox(height: 16),
            lookupPanel,
          ],
        ),
      ),
    );
  }

  Widget _buildCameraBox(double height) {
    return ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.box),
              child: Container(
                height: height,
                color: AppColors.brown950,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!_cameraOn)
                      Container(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            radius: 1.1,
                            colors: [AppColors.brown800, AppColors.brown950],
                          ),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: AppColors.terracotta.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.qr_code_scanner_rounded, size: 48, color: AppColors.terracotta),
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                'Kamera Kapalı',
                                style: TextStyle(color: AppColors.brown200, fontWeight: FontWeight.w600, fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_cameraOn) ...[
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
                            borderRadius: BorderRadius.circular(AppRadius.box),
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
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: Center(
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(AppRadius.box),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(AppRadius.box),
                            onTap: _toggleCamera,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_cameraOn ? Icons.videocam_off : Icons.videocam, color: Colors.white, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    _cameraOn ? 'Kamerayı Durdur' : 'Kamerayı Başlat',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
  }

  Widget _buildLookupContent(bool desktop) {
    final state = _lookup;
    if (state is _Idle) {
      return Text(
        'Bir ürün tarayın, burada görünecek.',
        style: TextStyle(color: AppColors.brown400, fontSize: desktop ? 18 : 14),
      );
    }
    if (state is _Loading) {
      return Text('Aranıyor: ${state.barcode}…', style: TextStyle(color: AppColors.brown500, fontSize: desktop ? 18 : 14));
    }
    if (state is _NotFound) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Ürün bulunamadı', style: TextStyle(color: AppColors.terracotta, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Barkod: ${state.barcode}', style: const TextStyle(color: AppColors.brown500)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ProductCreateScreen(initialBarcode: state.barcode)),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.brown300, width: 2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            icon: const Icon(Icons.add_circle_outline, size: 18, color: AppColors.brown700),
            label: const Text('Yeni Ürün Oluştur', style: TextStyle(color: AppColors.brown700)),
          ),
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
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: desktop ? 24 : 16, color: AppColors.brown900),
        ),
        SizedBox(height: desktop ? 8 : 4),
        Text(
          'Barkod: ${product.barcode}',
          style: TextStyle(color: AppColors.brown500, fontSize: desktop ? 16 : 14),
        ),
        SizedBox(height: desktop ? 16 : 8),
        Row(
          children: [
            _pill(formatPrice(product.price), desktop),
            const SizedBox(width: 8),
            _pill(product.stockunit ?? '-', desktop),
          ],
        ),
        SizedBox(height: desktop ? 28 : 12),
        Row(
          children: [
            Expanded(flex: 2, child: SizedBox(height: desktop ? 52 : null, child: AddToListButton(product: product))),
            const SizedBox(width: 8),
            Expanded(child: SizedBox(height: desktop ? 52 : null, child: EditProductButton(product: product))),
            const SizedBox(width: 8),
            Expanded(child: SizedBox(height: desktop ? 52 : 48, child: PrintLabelButton(barcode: product.barcode))),
          ],
        ),
      ],
    );
  }

  Widget _pill(String text, bool desktop) => Container(
        padding: EdgeInsets.symmetric(horizontal: desktop ? 14 : 10, vertical: desktop ? 8 : 5),
        decoration: BoxDecoration(color: AppColors.brown100, borderRadius: BorderRadius.circular(AppRadius.chip)),
        child: Text(
          text,
          style: TextStyle(color: AppColors.brown800, fontWeight: FontWeight.w600, fontSize: desktop ? 18 : 14),
        ),
      );
}
