import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data_repo.dart';

/// A background isolate entry point. The nightly "Günlük Özet" is sent as a
/// `notification` message, which Android displays on its own -- there is
/// nothing to do here, but FCM requires the handler to be registered.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {}

/// FCM registration for the nightly Günlük Özet push. Android only -- iOS
/// would need APNs (out of scope) and desktop has no FCM. Every signed-in
/// Android device registers its token in `push_devices`; the owner turns
/// `enabled` on for the (few) devices that should actually get the push,
/// from the desktop Ayarlar -> Bildirimler list.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _started = false;
  String? _token;

  bool get _supported => !kIsWeb && Platform.isAndroid;

  // Notification-tap routing (currently only "kasap_sale", see
  // home_shell.dart's _handleNotificationTap) -- a warm/background tap comes
  // through [onNotificationTap] live; a cold-start tap (app was killed) is
  // instead captured once here and handed to whoever calls
  // [consumePendingInitialTap] after the widget tree is up, since a
  // broadcast stream would otherwise drop an event emitted before HomeShell
  // has a chance to subscribe.
  final _tapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationTap => _tapController.stream;
  Map<String, dynamic>? _pendingInitialTap;

  Map<String, dynamic>? consumePendingInitialTap() {
    final data = _pendingInitialTap;
    _pendingInitialTap = null;
    return data;
  }

  /// One-time Firebase + FCM setup. Safe to call before login (registration
  /// will just be retried later via [syncToken]).
  Future<void> init() async {
    if (!_supported || _started) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(); // Android 13+ POST_NOTIFICATIONS prompt
      _token = await fm.getToken();
      fm.onTokenRefresh.listen((t) {
        _token = t;
        _register(t);
      });
      await syncToken();
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _tapController.add(m.data));
      final initialMessage = await fm.getInitialMessage();
      if (initialMessage != null) _pendingInitialTap = initialMessage.data;
    } catch (e) {
      debugPrint('PushService init failed (non-fatal): $e');
    }
  }

  /// Re-registers the current token -- called again once the user is signed
  /// in (the pre-login attempt fails RLS silently).
  Future<void> syncToken() async {
    if (!_supported) return;
    if (Supabase.instance.client.auth.currentSession == null) return;
    final token = _token ?? await FirebaseMessaging.instance.getToken();
    if (token != null) {
      _token = token;
      await _register(token);
    }
  }

  Future<void> _register(String token) async {
    try {
      final name = await DataRepo().getStaffName();
      // upsert only sets the columns sent -> `enabled` (the owner's choice)
      // is preserved across re-registrations.
      await Supabase.instance.client.from('push_devices').upsert({
        'fcm_token': token,
        'staff_name': name,
        'platform': 'android',
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'fcm_token');
    } catch (e) {
      debugPrint('push token register failed (non-fatal): $e');
    }
  }
}

/// One row of `push_devices`, for the desktop Ayarlar -> Bildirimler list.
class PushDevice {
  final String token;
  final String? staffName;
  final String platform;
  final bool enabled;
  final DateTime? lastSeenAt;

  PushDevice({
    required this.token,
    this.staffName,
    required this.platform,
    required this.enabled,
    this.lastSeenAt,
  });

  factory PushDevice.fromJson(Map<String, dynamic> j) => PushDevice(
        token: j['fcm_token'] as String,
        staffName: (j['staff_name'] as String?)?.trim().isNotEmpty == true ? (j['staff_name'] as String).trim() : null,
        platform: (j['platform'] as String?) ?? 'android',
        enabled: j['enabled'] as bool? ?? false,
        lastSeenAt: j['last_seen_at'] != null ? DateTime.parse(j['last_seen_at'] as String) : null,
      );

  /// Last 4 of the token -- enough to tell two devices apart in the list.
  String get shortId => token.length > 6 ? '…${token.substring(token.length - 6)}' : token;
}

/// Read/write helpers for the Bildirimler settings screen (desktop).
class PushAdmin {
  final _client = Supabase.instance.client;

  Future<List<PushDevice>> listDevices() async {
    final rows = await _client
        .from('push_devices')
        .select('fcm_token, staff_name, platform, enabled, last_seen_at')
        .order('enabled', ascending: false)
        .order('last_seen_at', ascending: false)
        .timeout(const Duration(seconds: 8));
    return rows.map((r) => PushDevice.fromJson(r)).toList();
  }

  Future<void> setEnabled(String token, bool enabled) =>
      _client.from('push_devices').update({'enabled': enabled}).eq('fcm_token', token);

  Future<void> remove(String token) =>
      _client.from('push_devices').delete().eq('fcm_token', token);
}
