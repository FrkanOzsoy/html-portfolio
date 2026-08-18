# Barkod Tarayıcı (Flutter)

Native barcode scanning app for the supermarket product/list system — replaces the earlier
web app (browser camera APIs couldn't do real autofocus control or fast enough scanning).
Uses `mobile_scanner`, which wraps **Google ML Kit** on Android and **Apple Vision/AVFoundation**
on iOS for real native scanning performance.

## Architecture

- Talks **directly to Supabase** (no backend server) — `supabase_flutter`, anon key + Row Level
  Security. See `barkod-tarayici/supabase/schema.sql` (sibling repo) for the policies.
- Auth: a single shared staff account (`personel@barkod-tarayici.local`), not per-user logins —
  matches the store's one-shared-password model. Staff only ever see/enter the shared password;
  the fixed email is an implementation detail in `lib/config.dart`.
- `lib/data_repo.dart` is the whole data layer: product lookup/search (Turkish-fold search
  ported from the old web app's `normalize.ts`), list CRUD, CSV export built client-side.

## Android — buildable from this Windows machine

```bash
flutter pub get
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

Sideload: copy the APK to the phone, enable "Install unknown apps" for whatever app you use to
open it (Files, Drive, etc.), then open the APK to install. No Play Store involved.

**Known local friction**: this project lives in a OneDrive-synced folder, and OneDrive
periodically locks `ios/Flutter/ephemeral/*` while Flutter is trying to delete/regenerate it,
which can make `flutter analyze` / `flutter build` fail with a "failed to delete a directory"
error. If that happens, just delete `ios/Flutter/ephemeral` manually and re-run — it's fully
regenerated, nothing of value lives there.

## iOS — must be done on a Mac (Xcode has no Windows version)

This machine cannot build or sign iOS apps at all. Do this on your Mac, using the same project
(it'll already be here once OneDrive finishes syncing this folder).

### One-time setup

1. Install Xcode from the Mac App Store, open it once to accept the license and install
   additional components.
2. Install Flutter on the Mac: https://docs.flutter.dev/get-started/install/macos
3. Enroll in the **Apple Developer Program** at https://developer.apple.com/programs/ — **$99/year**,
   tied to your Apple ID. Required for both device testing and TestFlight.
4. Install CocoaPods if you don't have it: `sudo gem install cocoapods`

### Build & upload

```bash
cd barkod-tarayici-app
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace   # NOT Runner.xcodeproj — must be the workspace
```

In Xcode:

1. Select the **Runner** target → **Signing & Capabilities**.
2. Under **Team**, pick your Apple Developer account (sign in via Xcode → Settings → Accounts
   first if it's not listed).
3. Set a unique **Bundle Identifier** if `com.barkodtarayici.barkodTarayici` isn't available to
   you — with automatic signing on, Xcode registers the App ID for you.
4. Top menu: **Product → Destination → Any iOS Device (arm64)** (archiving needs a real-device
   destination, not a simulator).
5. **Product → Archive**. Wait for it to build — first archive can take several minutes.
6. When the **Organizer** window opens with your archive: **Distribute App → App Store Connect
   → Upload**. Follow the prompts (automatic signing is fine).

### TestFlight

1. Go to https://appstoreconnect.apple.com → **My Apps** → create a new app if this is the
   first upload (matching the bundle ID from Xcode).
2. Open the app → **TestFlight** tab. The build you uploaded appears after Apple finishes
   processing it (usually 10–30 minutes; you'll get an email).
3. **Internal Testing**: add testers by their Apple ID email (must be added as a user on your
   App Store Connect team first, under Users and Access). Internal testers get the build
   **immediately, no App Review needed** — good enough for your father's staff if you add
   their Apple IDs to the team.
4. **External Testing** (if you want testers outside your team, up to 10,000 people): requires
   a quick **Beta App Review** from Apple, typically 24–48 hours, before the first build goes out.
5. Testers install the **TestFlight** app from the App Store, accept the email/link invite, and
   install your app through it. Builds expire after 90 days — you re-upload periodically.

### Notes

- `ios/Runner/Info.plist` already has the required `NSCameraUsageDescription` — the app would
  otherwise silently crash when it first tries to access the camera on iOS.
- Re-run `pod install` any time you change `pubspec.yaml` dependencies before opening Xcode again.
