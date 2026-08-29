# Nightly "Günlük Özet" push notification

At **23:30 Türkiye time** every day, the 2 (or however many) enabled Android
devices get an FCM push with the day's kasa summary. Tapping it opens the
İstatistik tab.

```
📊 29 Ağustos — Günlük Özet
💰 Ciro: 92.959 ₺ (geçen hafta 93.913 ₺, −%1)
🧾 327 fiş · ort. sepet 284 ₺ · 864 ürün
💵 Nakit 21.486 ₺   💳 Kart 71.474 ₺
     └ Mastercard %64 · Visa %28 · Troy %7
❌ İptal: 28 fiş (22.043 ₺)
🔥 En yoğun saat: 15:00
🏆 TRANÇ · KIYMA · TEMEL GIDA
```

## Pieces

| Component | Location | Status |
|---|---|---|
| `push_devices` table + `kasa_day_summary_json(date)` fn | `db/2026-08-29_push_devices.sql` | **applied** |
| `daily-summary-push` edge function | `C:\Digisoft\SupabaseSync\supabase\functions\daily-summary-push\` (not tracked) | **deployed** |
| `pg_cron` + `pg_net` | Supabase | **enabled** |
| cron job (`30 20 * * *`) | `db/2026-08-29_push_cron.sql` | **scheduled** (secret in Vault: `push_cron_secret`) |
| Firebase project `ccm-barkod` | project #212623614359, Android app `1:212623614359:android:ef6ed8b0c253628aa6a4d2` | **created** (via firebase CLI) |
| secrets `FCM_PROJECT_ID` / `FCM_SERVICE_ACCOUNT` / `PUSH_CRON_SECRET` | Supabase | **set** |
| Flutter FCM integration | `lib/push_service.dart` + `android/` + Ayarlar → Bildirimler | **coded** |
| Shorebird release + install on 2 phones + enable in Ayarlar | — | **pending** |

Server side tested end-to-end: `net.http_post` from Postgres → edge fn → 200,
message formats correctly, the service-account JWT → FCM v1 auth works, dead
tokens are pruned.

## Remaining setup

### 1. Firebase project (owner, ~10 min)

1. [console.firebase.google.com](https://console.firebase.google.com) → **Add project** → e.g. `ccm-barkod` → skip Analytics.
2. **Add app → Android**, package `com.barkodtarayici.barkod_tarayici` → download **`google-services.json`** → `android/app/google-services.json`.
3. **Project settings → Service accounts → Generate new private key** → the JSON is the FCM credential.
4. Note the **project id** (Project settings → General).

### 2. Supabase secrets

```
supabase secrets set FCM_PROJECT_ID=ccm-barkod-xxxxx
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
supabase functions deploy daily-summary-push --no-verify-jwt
```

### 3. Cron (23:30 Türkiye = 20:30 UTC)

```sql
select cron.schedule(
  'daily-summary-push', '30 20 * * *', $$
  select net.http_post(
    url     := 'https://ioguubjvmpfaqshwrkvd.supabase.co/functions/v1/daily-summary-push',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true),
      'Content-Type',  'application/json')
  ) $$
);
```
(The service-role key is passed via a header the function verifies. Store it
with `alter database postgres set app.settings.service_role_key = '...'` or
inline it in the cron command — Supabase Vault is the tidier option.)

### 4. Flutter (needs a new Shorebird release — native change)

- `pubspec.yaml`: `firebase_core`, `firebase_messaging`, `flutter_local_notifications`
- `android/build.gradle` + `android/app/build.gradle`: `com.google.gms.google-services` plugin
- `lib/push_service.dart`: request POST_NOTIFICATIONS (Android 13+), get the FCM
  token, upsert `push_devices {fcm_token, staff_name, platform:'android'}` on
  launch + on token refresh; background handler (top-level fn); create the
  `daily_summary` notification channel; `onMessageOpenedApp` → jump to İstatistik.
- `main.dart`: `Firebase.initializeApp()` + `PushService.instance.init()` after login.
- **Desktop Ayarlar → Bildirimler**: list every `push_devices` row (staff name,
  platform, last seen) with an `enabled` switch. Owner turns on exactly the
  devices that should get the push. No mobile UI needed.
- `shorebird release android` (bump to e.g. 1.9.6+2029), upload APK, update
  `app_releases`, reinstall on the 2 phones. Feature is inert on every device
  until the owner enables it in Ayarlar.

## Test without waiting for 23:30

```
curl -X POST 'https://ioguubjvmpfaqshwrkvd.supabase.co/functions/v1/daily-summary-push?day=2026-08-29' \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
```
Returns `{sent, stale, title, body}`.
