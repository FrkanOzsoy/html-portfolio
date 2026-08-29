# Shorebird iOS setup — brief for the macOS builder agent

**Goal:** cut the **first Shorebird iOS release** of ÇÇM-Barkod Okuyucu on a Mac, install it on
the owner's iOS device(s) once, and hand back the ability to ship all future Dart/UI changes
as OTA patches from Windows (no Mac, no rebuild, no re-sign).

This is a one-time job. After it's done the Mac is only needed again ~once a year (provisioning
profile expiry) or when a native dependency / plugin / permission / icon changes.

---

## Where we are now

| Thing | State |
|---|---|
| Shorebird account | `furkan.ozsoy09@gmail.com`, personal org id `56113` (owner) |
| App registered with Shorebird | yes — `app_id: 1086d240-c49a-449d-9d14-e0c6076dca7e` |
| `shorebird.yaml` | committed at repo root, listed in `pubspec.yaml` assets. **Do not regenerate it.** `auto_update` is on (patches land silently on next launch). |
| Android | **done** — release `1.9.5+2028` published and active, APK distributed via Supabase. |
| iOS | **not started** — this doc. `shorebird init` touched no iOS files; the Runner project is stock. |
| Flutter | Shorebird ships its own fork. The Android release used **Flutter 3.47.2 (revision `e16cf749ccaa38d7050335ff305def49b1c7c84c`)**, Shorebird CLI `1.6.120`. Use the same for iOS. |

### App identity / project facts

- Repo: `github.com/FrkanOzsoy/html-portfolio` (misleading name; it is the Flutter app). Branch: `main`, trunk-based, commit straight to main.
- iOS bundle id: `com.barkodtarayici.barkodTarayici`
- `IPHONEOS_DEPLOYMENT_TARGET = 15.0`
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the pbxproj are stale (`1.0` / `1`); the build
  reads `$(FLUTTER_BUILD_NUMBER)` / `$(FLUTTER_BUILD_NAME)` from `pubspec.yaml` → currently
  `version: 1.9.5+2028`. Ship the iOS release as **build-name `1.9.5`, build-number `2028`** to
  match Android (pubspec already says this — no flag needed).
- No `ios/Podfile` yet — `flutter precache --ios` + first build generates it. `pod install` will run.
- Plugins with native iOS code: `mobile_scanner`, `supabase_flutter`, `connectivity_plus`,
  `shared_preferences`, `url_launcher`, `sqflite`, `path_provider`, `file_picker` /
  `android_file_picker` (the latter is Android-only, harmless on iOS), `syncfusion_flutter_pdf`
  (pure Dart). Nothing exotic; a normal `flutter build ipa` should succeed.
- `lib/update_checker.dart` (the in-app "new APK available" prompt) is **Android-only** — iOS
  has no self-updater, so Shorebird `auto_update` is the entire iOS update story. Good.

---

## What you need on the Mac

1. **Xcode** (matching or newer than the Flutter 3.47.2 fork's requirement — Xcode 15+/16),
   plus `xcodebuild -runFirstLaunch` and Command Line Tools.
2. **CocoaPods** (`sudo gem install cocoapods` or brew).
3. **Apple Developer Program account** for the team that owns bundle id
   `com.barkodtarayici.barkodTarayici`, signed into Xcode (Settings → Accounts). Ask the owner
   to add you / provide an App Store Connect API key, **or** run this on the owner's own Mac
   session so their signing identity + provisioning profile are already there.
4. **A signing identity + provisioning profile** that can install on the target device(s).
   Distribution is **private / ad-hoc** (owner's words: "a manual device build that lasts 1 year")
   — NOT App Store. So: ad-hoc distribution profile with the device UDIDs registered, or a
   development profile. Confirm with the owner which they use and get the device UDIDs if ad-hoc.
5. **Shorebird CLI**: `curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh | bash`
   then `shorebird login` as `furkan.ozsoy09@gmail.com` (owner must do the browser step, or
   supply a `SHOREBIRD_TOKEN` via `shorebird login --token`).
6. Clone the repo, `git checkout main`, `git pull`.
   - If the Mac username has non-ASCII characters, set `PUB_CACHE` to a plain-ASCII path before
     `flutter pub get` (this bit us on Windows with `jni`'s CMake build). Most Macs are fine.

---

## Steps

```bash
# 0. from repo root, main, clean
shorebird doctor            # expect no issues; it re-checks the iOS side

# 1. sanity: a plain Flutter iOS build must succeed first
flutter pub get
flutter build ipa --release --export-method ad-hoc   # or open Runner.xcworkspace and Archive
# fix any signing / pod errors here — if this fails it is NOT a Shorebird problem

# 2. cut the Shorebird release (pin the Flutter version to match Android)
shorebird release ios \
  --flutter-version=3.47.2 \
  --build-name=1.9.5 \
  --build-number=2028
# It builds an .xcarchive, uploads the release to Shorebird, and prints the path to the
# archive / IPA. Note the exact "release version" string it reports (should be "1.9.5+2028").
```

`shorebird release ios` produces an archive you still have to **export + sign + distribute
yourself** (Xcode Organizer → Distribute App → Ad Hoc, or `xcodebuild -exportArchive` with an
export options plist). Shorebird only handles the code-push registration.

```bash
# 3. export a signed ad-hoc IPA from the archive, e.g.
xcodebuild -exportArchive \
  -archivePath build/ios/archive/Runner.xcarchive \
  -exportPath build/ios/ipa \
  -exportOptionsPlist ExportOptions-adhoc.plist
```

Install the resulting IPA on the device(s) (Apple Configurator, Xcode Devices window, or the
owner's usual method).

---

## After the release is live

Verify: `shorebird releases list --platform ios` shows `1.9.5+2028` active.

From then on, **any Dart/asset change** ships from Windows with:

```bash
shorebird patch ios --release-version=1.9.5+2028
```

Patchable: new screens, logic, Supabase queries / RPCs / **new edge functions**, bug fixes,
strings, assets in already-declared folders.
NOT patchable (needs a new `shorebird release ios` on a Mac + reinstall): new/upgraded plugin,
new permission, app icon/name/bundle-id change, Flutter engine bump, new pubspec asset folder.

Keep every device on the same release version or it won't receive patches.

---

## What to commit / report back

- If the build required **any** repo change (Podfile, `ios/` project settings, an
  `ExportOptions*.plist`, deployment-target bump, a plugin pin), commit it to `main` with a
  clear message and push. Co-author trailer:
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`
- Report: the exact release-version string Shorebird recorded, the Flutter/Shorebird versions
  used, the signing method (ad-hoc vs development) and profile expiry date, and where the signed
  IPA is. Add a short note to `docs/` (or update this file) with the iOS row filled in so the
  next person knows the patch command and the yearly-rebuild deadline.
- Update the memory note `barkod-shorebird` equivalent if you keep one.
