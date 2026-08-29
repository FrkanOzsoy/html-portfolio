import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_settings.dart';
import 'config.dart';
import 'platform_util.dart';
import 'route_observer.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/home_shell.dart';

void main() {
  // Supabase's realtime client can throw async errors (a subscribe attempt
  // timing out, or -- as found once already -- a table that was never added
  // to the realtime publication) from deep inside its own internal
  // callbacks, in places no amount of `onError` on our own `.listen()`
  // calls can reach. Those are meant to be non-fatal (the client keeps
  // retrying on its own), but left uncaught they're unhandled exceptions at
  // the zone root -- this is the app-wide backstop so one flaky realtime
  // subscription can never take down anything else.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // sqflite's own plugin only ships Android/iOS/macOS implementations --
      // this FFI factory lets the same LocalDb code also run on a Windows
      // desktop build, purely so this app can be previewed live during
      // development (`flutter run -d windows`). The shipped Android build
      // never takes this branch.
      if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
      await appSettings.load();
      runApp(const BarkodTarayiciApp());
    },
    (error, stack) => debugPrint('Uncaught async error (non-fatal): $error'),
  );
}

class BarkodTarayiciApp extends StatelessWidget {
  const BarkodTarayiciApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds when the user changes a setting on the Ayarlar tab -- text
    // scale is applied app-wide here so every screen picks it up, density
    // flows through the theme.
    return AnimatedBuilder(
      animation: appSettings,
      builder: (context, _) => MaterialApp(
        title: 'ÇÇM-Barkod Okuyucu',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(desktop: isDesktopPlatform, compact: appSettings.compact),
        locale: const Locale('tr', 'TR'),
        navigatorObservers: [routeObserver],
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: appSettings.textScale,
          maxScaleFactor: appSettings.textScale,
          child: child!,
        ),
        home: Supabase.instance.client.auth.currentSession != null
            ? const HomeShell()
            : const LoginScreen(),
      ),
    );
  }
}
