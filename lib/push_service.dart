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

  Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid || _started) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(); // Android 13+ POST_NOTIFICATIONS prompt

      final token = await fm.getToken();
      if (token != null) await _register(token);
      fm.onTokenRefresh.listen(_register);
    } catch (e) {
      debugPrint('PushService init failed (non-fatal): $e');
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
