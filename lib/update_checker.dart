import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

/// One row, read from the `app_releases` table -- see
/// barkod-tarayici/supabase/schema.sql. Published by whoever ships a new
/// build (today: manually via the Supabase Storage + table upsert; see
/// barkod-tarayici-app/scripts/publish_release.sh).
class ReleaseInfo {
  final int versionCode;
  final String versionName;
  final String apkPath;
  final String? changelog;

  ReleaseInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkPath,
    this.changelog,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) => ReleaseInfo(
        versionCode: json['version_code'] as int,
        versionName: json['version_name'] as String,
        apkPath: json['apk_path'] as String,
        changelog: json['changelog'] as String?,
      );

  String get downloadUrl => '$supabaseUrl/storage/v1/object/public/app-releases/$apkPath';
}

class UpdateChecker {
  /// Returns the published release if it's newer than the running app,
  /// null if up to date or the check couldn't complete (offline, till-side
  /// hiccup, etc. -- never blocks app startup on this).
  Future<ReleaseInfo?> checkForUpdate() async {
    if (!Platform.isAndroid) return null;
    try {
      final row = await Supabase.instance.client
          .from('app_releases')
          .select('version_code, version_name, apk_path, changelog')
          .eq('id', 1)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (row == null) return null;

      final release = ReleaseInfo.fromJson(row);
      final info = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(info.buildNumber) ?? 0;
      return release.versionCode > currentCode ? release : null;
    } catch (_) {
      return null;
    }
  }
}
