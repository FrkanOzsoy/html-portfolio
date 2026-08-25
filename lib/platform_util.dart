import 'dart:io';

/// True on any non-mobile platform (Windows, and Linux/macOS if this is
/// ever built for them) -- used to switch specific screens to a
/// desktop-shaped layout (a top menu instead of bottom tabs, a dense
/// Excel-style table instead of cards, etc.) instead of the phone/tablet
/// layout everything else uses.
bool get isDesktopPlatform => !Platform.isAndroid && !Platform.isIOS;
