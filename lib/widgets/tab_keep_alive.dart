import 'package:flutter/material.dart';

/// Keeps [child]'s whole widget subtree alive inside a [PageView] (which is
/// what [TabBarView] is built on) instead of letting it be disposed and
/// rebuilt from scratch every time it scrolls off-screen and back. Wrap
/// each TabBarView child in this -- the standard fix for a tab's state
/// (animations, streams, in-progress edits) resetting or breaking when you
/// switch away and back.
///
/// Named `TabKeepAlive` (not `KeepAlive`) to avoid colliding with Flutter's
/// own `package:flutter/widgets.dart` `KeepAlive` (a lower-level sliver
/// primitive, not what you want here).
class TabKeepAlive extends StatefulWidget {
  final Widget child;
  const TabKeepAlive({super.key, required this.child});

  @override
  State<TabKeepAlive> createState() => _TabKeepAliveState();
}

class _TabKeepAliveState extends State<TabKeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
