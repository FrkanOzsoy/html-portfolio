import 'package:flutter/material.dart';
import '../theme.dart';

/// A "boxy, just a little rounded" action button -- used in place of a
/// default circular [IconButton] for card-level actions (cancel/revoke,
/// edit, delete) throughout the app, per the app's design language.
class SquareIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  const SquareIconButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.tooltip,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: onPressed == null ? color.withValues(alpha: 0.4) : color, size: size * 0.5),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
