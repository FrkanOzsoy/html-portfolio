import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';

/// A button for actions that create a row in a till-PC request-queue table
/// (label print, product create/delete, Teraziye export...) and must wait
/// for the till-PC service to actually process it. Unlike
/// [ServerActionButton] (one flat await, used for the Kasaya Gönder send
/// buttons where `sendPendingChange` already fully resolves before
/// returning), this shows pending -> processing -> done/error text below
/// the button, and gives up after 10s with a "check yourself" message if
/// nothing ever comes back -- the shared shape of every till-PC
/// request-queue action in this app (see product_edit_screen.dart's label
/// print section and product_create_screen.dart for the same pattern).
class QueuedActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool enabled;

  /// Fill color for the idle button -- brown800 (the app's one "primary
  /// commit action" color) unless overridden, e.g. terracotta for a
  /// destructive action like product deletion.
  final Color color;

  /// Fires the request and returns its row id in the queue table.
  final Future<int> Function() onSubmit;

  /// Polls status for that id, yielding until a terminal status.
  final Stream<({String status, String? errorMessage})> Function(int id) watchStatus;

  /// Called once a terminal status is reached ('done', 'error', or the
  /// client-side 'timeout') -- e.g. to clear form state on success.
  final void Function(String finalStatus)? onFinished;

  /// Inner padding of the button itself -- bumped up where the button is
  /// the screen's single primary action (e.g. the Teraziye Gönder screen's
  /// pinned send buttons) so it doesn't read as a thin strip.
  final EdgeInsetsGeometry padding;

  const QueuedActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onSubmit,
    required this.watchStatus,
    this.enabled = true,
    this.color = AppColors.brown800,
    this.onFinished,
    this.padding = const EdgeInsets.symmetric(vertical: 14),
  });

  @override
  State<QueuedActionButton> createState() => _QueuedActionButtonState();
}

class _QueuedActionButtonState extends State<QueuedActionButton> {
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

  Future<void> _fire() async {
    _timeoutTimer?.cancel();
    setState(() {
      _status = 'pending';
      _errorMessage = null;
    });
    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _busy) setState(() => _status = 'timeout');
    });
    try {
      final id = await widget.onSubmit();
      _sub?.cancel();
      _sub = widget.watchStatus(id).listen((s) {
        if (!mounted) return;
        setState(() {
          _status = s.status;
          _errorMessage = s.errorMessage;
        });
        if (s.status == 'done' || s.status == 'error') {
          _timeoutTimer?.cancel();
          widget.onFinished?.call(s.status);
        }
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
        'processing' => 'İşleniyor…',
        'done' => 'Tamamlandı ✓',
        'error' => _errorMessage ?? 'Hata oluştu',
        'timeout' => 'Yanıt alınamadı -- kasa bilgisayarını kendiniz kontrol edin.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          onPressed: _busy || !widget.enabled ? null : _fire,
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.color,
            padding: widget.padding,
          ),
          icon: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Icon(widget.icon, size: 18),
          label: Text(widget.label),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_statusText, style: TextStyle(color: _statusColor, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}
