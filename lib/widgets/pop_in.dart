import 'package:flutter/material.dart';

/// Plays a quick, understated entrance (a slight scale-up + fade, easing
/// out with no overshoot) the moment this widget is actually mounted. Wrap
/// a list item's card with this and nothing more is needed to scope it
/// correctly: Flutter only re-runs [initState] when an Element is newly
/// inserted for a given key/slot, so an item that was already on screen and
/// is just being rebuilt (unrelated state change elsewhere in the list)
/// keeps its existing State and never replays this -- only a genuinely new
/// entry (freshly added, or reappearing after an undo-restore, since
/// deletion tore the old Element down) does.
class PopIn extends StatefulWidget {
  final Widget child;
  const PopIn({super.key, required this.child});

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260))..forward();
  // A small begin scale (not 0) so a nearly full-width card just gently
  // settles into place instead of visibly growing across the screen.
  late final Animation<double> _scale =
      Tween<double>(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: Transform.scale(scale: _scale.value, child: child),
      ),
      child: widget.child,
    );
  }
}
