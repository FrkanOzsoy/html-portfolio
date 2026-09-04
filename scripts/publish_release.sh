#!/usr/bin/env bash
# Publish a new release: bumps pubspec.yaml, builds the arm64 release APK,
# uploads it to the Supabase Storage `app-releases` bucket, and upserts the
# `app_releases` config row the app's in-app update checker reads
# (lib/update_checker.dart).
#
# Usage:
#   SUPABASE_SERVICE_ROLE_KEY=... scripts/publish_release.sh 1.4.0 4 "Fixed X, added Y"
#
# The service_role key is required as an env var (never hardcoded here --
# this script is meant to be committed) since it can write past RLS.
set -euo pipefail

VERSION_NAME="${1:?Usage: publish_release.sh <version_name> <version_code> <changelog>}"
VERSION_CODE="${2:?version_code required}"
CHANGELOG="${3:-}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY in the environment first}"

SUPABASE_URL="https://ioguubjvmpfaqshwrkvd.supabase.co"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_NAME="ccm-barkod-okuyucu-v${VERSION_NAME}.apk"

echo "==> Bumping pubspec.yaml to ${VERSION_NAME}+${VERSION_CODE}"
sed -i "s/^version: .*/version: ${VERSION_NAME}+${VERSION_CODE}/" "$REPO_ROOT/pubspec.yaml"

echo "==> Pausing OneDrive (avoids file-lock races with Gradle on this machine)"
powershell.exe -NoProfile -Command "Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue" || true
sleep 2

cleanup() {
  echo "==> Resuming OneDrive"
  powershell.exe -NoProfile -Command "Start-Process 'C:\\Program Files\\Microsoft OneDrive\\OneDrive.exe'" || true
}
trap cleanup EXIT

echo "==> Clean build"
rm -rf "$REPO_ROOT/build"
cd "$REPO_ROOT"
flutter pub get
# Plain `flutter build apk` does NOT embed the Shorebird updater engine --
# an APK built that way can never receive `shorebird patch` updates, even
# though `shorebird patch` itself succeeds silently against the release
# record. The distributed APK must come from `shorebird release`, which
# builds via Shorebird's engine and registers the release so patches apply.
shorebird release android --artifact apk --target-platform android-arm64

APK_PATH="$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK_PATH" ] || { echo "Build did not produce $APK_PATH"; exit 1; }

# The value in pubspec.yaml is NOT necessarily what's installed on the
# device -- the update checker (lib/update_checker.dart) compares against
# the real installed versionCode via package_info_plus, so app_releases must
# store that same real number or the comparison silently never fires.
AAPT="$(find /c/devtools/android-sdk/build-tools -iname 'aapt.exe' 2>/dev/null | sort -V | tail -1)"
[ -n "$AAPT" ] || { echo "aapt not found under /c/devtools/android-sdk/build-tools"; exit 1; }
REAL_VERSION_CODE="$("$AAPT" dump badging "$APK_PATH" | grep -oP "versionCode='\K[0-9]+")"
[ -n "$REAL_VERSION_CODE" ] || { echo "Could not read versionCode from $APK_PATH"; exit 1; }
echo "==> pubspec build number ${VERSION_CODE} -> actual installed versionCode ${REAL_VERSION_CODE}"

echo "==> Uploading $APK_NAME to Supabase Storage"
# x-upsert lets this overwrite an existing object instead of failing with a
# 409 -- version names get reused over time (e.g. after resetting the
# numbering scheme), and only app_releases' single row actually determines
# what the update checker offers, so an old object under the same name is
# never worth preserving over a fresh upload.
curl -sf -X POST "$SUPABASE_URL/storage/v1/object/app-releases/$APK_NAME" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/vnd.android.package-archive" \
  -H "x-upsert: true" \
  --data-binary "@$APK_PATH"

echo "==> Updating app_releases config row"
CHANGELOG_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$CHANGELOG")
curl -sf -X POST "$SUPABASE_URL/rest/v1/app_releases" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates" \
  --data "{\"id\":1,\"version_code\":${REAL_VERSION_CODE},\"version_name\":\"${VERSION_NAME}\",\"apk_path\":\"${APK_NAME}\",\"changelog\":${CHANGELOG_JSON}}"

echo ""
echo "==> Done. Download URL:"
echo "$SUPABASE_URL/storage/v1/object/public/app-releases/$APK_NAME"
