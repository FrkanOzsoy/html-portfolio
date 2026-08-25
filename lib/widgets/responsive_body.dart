import 'package:flutter/material.dart';

/// Caps content width and centers it on wide screens (tablets, foldables
/// unfolded, desktop-window Android) so the app doesn't stretch
/// edge-to-edge into unreadably wide rows of text and controls. A no-op on
/// phones, since their width is almost always under [maxWidth] already.
class ResponsiveBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ResponsiveBody({super.key, required this.child, this.maxWidth = 640});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
