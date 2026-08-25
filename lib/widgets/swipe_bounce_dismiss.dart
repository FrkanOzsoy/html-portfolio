import 'package:flutter/material.dart';

/// Wraps a card so it can be removed via an explicit trigger (e.g. a
/// button tap), playing a quick shrink-and-fade exit first, then calling
/// [onDismiss] (local-first, so it's effectively instant -- the animation
/// is purely cosmetic, not something the data change waits on).
///
/// Deliberately does NOT respond to swipe gestures -- horizontal swipes are
/// reserved app-wide for switching between the main tabs (see
/// `home_shell.dart`), so a swipe here must never also clear the item.
class SwipeBounceDismiss extends StatefulWidget {
  final Key itemKey;
  final Widget Function(VoidCallback triggerDismiss) builder;
  final Future<void> Function() onDismiss;

  const SwipeBounceDismiss({required this.itemKey, required this.builder, required this.onDismiss})
      : super(key: itemKey);

  @override
  State<SwipeBounceDismiss> createState() => _SwipeBounceDismissState();
}

class _SwipeBounceDismissState extends State<SwipeBounceDismiss> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final Animation<double> _progress = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
  bool _dismissing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _triggerDismiss() async {
    if (_dismissing) return;
    setState(() => _dismissing = true);
    await _controller.forward();
    if (mounted) await widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.builder(_triggerDismiss);
    if (!_dismissing) return content;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) => Transform.scale(
        scale: (1 - _progress.value).clamp(0.0, 1.0),
        child: Opacity(opacity: (1 - _progress.value).clamp(0.0, 1.0), child: child),
      ),
      child: content,
    );
  }
}
