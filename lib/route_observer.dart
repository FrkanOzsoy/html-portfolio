import 'package:flutter/material.dart';

/// Shared instance so a screen can subscribe via [RouteAware] to learn when
/// it's covered by a route pushed on top of it (and should pause a live
/// camera session) or uncovered again -- see scanner_screen.dart. Registered
/// on the app's root Navigator in main.dart.
final routeObserver = RouteObserver<PageRoute<void>>();
