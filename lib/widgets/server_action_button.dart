import 'package:flutter/material.dart';
import '../theme.dart';

enum _Phase { idle, waiting, success, error }

/// A filled, rounded-rectangle action button for requests that must
/// actually round-trip to the server before reporting an outcome -- never
/// optimistic. Tapping "holds" (squeezes) while [onPressed] is in flight,
/// then pops and flashes green on success or red on failure before easing
/// back to [color].
class ServerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;

  /// Shown in place of [label] only during the success flash (e.g.
  /// "Kaydedildi" for a "Kaydet" button) -- omit to keep [label] unchanged
  /// throughout, which is what the Kasaya Gönder send buttons want.
  final String? successLabel;

  /// Returns true on success, false on failure. Exceptions count as failure.
  final Future<bool> Function() onPressed;

  /// Called once, right after the success flash appears, instead of the
  /// usual auto-revert-to-idle -- e.g. to navigate away a beat after the
  /// user has actually seen the checkmark. Only fires on success.
  final VoidCallback? onSuccess;

  const ServerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.enabled = true,
    this.successLabel,
    this.onSuccess,
  });

  @override
  State<ServerActionButton> createState() => _ServerActionButtonState();
}

class _ServerActionButtonState extends State<ServerActionButton> with SingleTickerProviderStateMixin {
  late final AnimationController _scale =
      AnimationController(vsync: this, value: 1.0, duration: const Duration(milliseconds: 450));
  _Phase _phase = _Phase.idle;

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  bool get _busy => _phase != _Phase.idle;

  Future<void> _handleTap() async {
    if (_busy) return;
    setState(() => _phase = _Phase.waiting);
    await _scale.animateTo(0.93, curve: Curves.easeOut, duration: const Duration(milliseconds: 120));

    bool ok;
    try {
      ok = await widget.onPressed();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;

    setState(() => _phase = ok ? _Phase.success : _Phase.error);
    await _scale.animateTo(1.0, curve: Curves.elasticOut, duration: const Duration(milliseconds: 550));
    if (ok && widget.onSuccess != null) {
      widget.onSuccess!();
      return;
    }
    await Future.delayed(const Duration(milliseconds: 850));
    if (!mounted) return;
    setState(() => _phase = _Phase.idle);
  }

  Color get _fillColor => switch (_phase) {
        _Phase.success => AppColors.success,
        _Phase.error => AppColors.terracotta,
        _ => widget.color,
      };

  @override
  Widget build(BuildContext context) {
    final tapDisabled = _busy || !widget.enabled;
    return AnimatedBuilder(
      animation: _scale,
      builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: !widget.enabled && _phase == _Phase.idle ? widget.color.withValues(alpha: 0.4) : _fillColor,
          borderRadius: BorderRadius.circular(AppRadius.box),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.box),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.box),
            onTap: tapDisabled ? null : _handleTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              child: Center(
                child: _phase == _Phase.waiting
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _phase == _Phase.success
                                ? Icons.check
                                : _phase == _Phase.error
                                    ? Icons.close
                                    : widget.icon,
                            size: 18,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _phase == _Phase.success && widget.successLabel != null ? widget.successLabel! : widget.label,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
