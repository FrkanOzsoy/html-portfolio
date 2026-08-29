# Session log — 2026-08-29

Everything done in one long working session on **ÇÇM-Barkod Okuyucu** (this
Flutter repo, the till‑PC daemon at `C:\Digisoft\SupabaseSync`, and the
Supabase backend `ioguubjvmpfaqshwrkvd`). Written start‑to‑finish for whoever
picks this up next.

Contents:

1. [Shorebird OTA — Android live](#1-shorebird-ota--android-live)
2. [Shorebird iOS — brief only](#2-shorebird-ios--brief-only)
3. [INTER_BOS recon — the till's live POS database](#3-inter_bos-recon)
4. [The "İstatistik" tab (was "Kasa")](#4-the-i̇statistik-tab)
5. [Fiş notes](#5-fiş-notes)
6. [Card‑payment detail](#6-card-payment-detail)
7. [The desktop shortcut trap](#7-the-desktop-shortcut-trap)
8. [Nightly "Günlük Özet" push notification (FCM)](#8-nightly-günlük-özet-push-fcm)
9. [İstatistik on mobile + profile‑picker login](#9-i̇statistik-on-mobile--profile-picker-login)
10. [Build / release reference](#10-build--release-reference)
11. [Commits](#11-commits)
12. [Still open](#12-still-open)

---

## 1. Shorebird OTA — Android live

**Goal:** stop rebuilding + re‑signing + reinstalling for every change. Shorebird
pushes compiled Dart + assets over the air; only native/plugin/pubspec changes
need a full release.

### What was done

- `shorebird init` had already run in the previous session. Verified: `shorebird.yaml`
  at repo root (`app_id: 1086d240-c49a-449d-9d14-e0c6076dca7e`), listed in
  `pubspec.yaml` assets, `shorebird doctor` clean.
- **First release: `1.9.5+2028`** — `shorebird release android --artifact apk
  --target-platform android-arm64`, published and active on Shorebird's servers.
- APK uploaded to Supabase Storage bucket `app-releases`, `app_releases` row
  (id 1) bumped so the in‑app updater offers it.

### Blockers fixed on the way

| Problem | Cause | Fix |
|---|---|---|
| Gradle "requires JVM 17" | machine default Java is 8 | `flutter config --jdk-dir="C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot"`; also export `JAVA_HOME` for shorebird |
| `[CXX1101] NDK … no source.properties` | `C:\Android\sdk\ndk\28.2.13676358` was an empty folder | `rm -rf` it, `sdkmanager --licenses`, `sdkmanager --install "ndk;28.2.13676358"` (r28c, 2.2 GB) |
| `ninja: chdir … jni-1.0.3\android\.cxx\… No such file` | the `jni` plugin (via `android_file_picker`) builds native C++ with CMake/ninja, which chokes on the **Turkish characters** in the default pub cache path `C:\Users\Çoban Çiftliği\AppData\Local\Pub\Cache` | relocate the cache: `PUB_CACHE=C:\pubcache`, `flutter pub get`, then build. **This env var is now required for every Android build on this machine.** |

### Versioning — why the build number is `2028` not `28`

Older releases were built with `--split-per-abi`, and Flutter's gradle adds a
`1000 * abiIndex` offset to the versionCode (arm64‑v8a → `+2000`). So
`pubspec 1.9.4+27` produced an installed APK with `versionCode 2027` (verified
with `aapt2 dump badging` on the live v1.9.4 APK).

Shorebird's `--artifact apk` builds a **universal** APK from the AAB, and Flutter
does **not** apply the ABI offset to a bundle → the versionCode would be the raw
build number (`28`), which is **lower than the installed 2027** and Android
refuses to install it as an update.

Fix: the build number is now the literal Android versionCode. From `1.9.5` on,
`pubspec` carries `+2028`, `+2029`, `+2030`… — bump by 1 per full release. There's
a comment in `pubspec.yaml` explaining this.

### The APK content‑type bug (bit us twice)

`supabase storage cp` auto‑detects an APK (a ZIP container) as
`Content-Type: application/zip`. Android's package installer then refuses it and
treats the download as an archive to browse — the user literally opened it
looking for "an apk file inside".

- Fix: always pass `--content-type "application/vnd.android.package-archive"` to
  `supabase storage cp`.
- **Cloudflare then poisoned the cache**: the wrong content‑type got cached
  against the file's ETag, and because re‑uploading the same bytes produces the
  same ETag, Cloudflare kept serving the stale header on 304 revalidation even
  after a correct re‑upload. Fix: upload under a **fresh object key**
  (`ccm-barkod-okuyucu-v1.9.5-b2028.apk`) and repoint `app_releases.apk_path`.
  Later releases just use `-v1.9.x.apk` (a genuinely new key each time).

### Ongoing patch workflow

```
shorebird patch android --release-version=1.9.7+2030   # runs from Windows
```
Dart/asset changes only: new screens, logic, Supabase queries, **new edge
functions** — all patchable. NOT patchable (needs a new `shorebird release`):
a new/upgraded plugin, a new permission, app icon/name, engine bump, a new
pubspec asset folder.

Memory: `barkod-shorebird`.

---

## 2. Shorebird iOS — brief only

The owner asked how to do the same for iOS. Key facts, written up in
`docs/shorebird-ios-setup.md`:

- **iOS releases must be built on a Mac** (Xcode is macOS‑only, same as Flutter).
  Patches (`shorebird patch ios`) run from Windows afterwards.
- Flow: one `shorebird release ios` on a Mac → sign with the owner's ad‑hoc
  profile (they do private, non‑App‑Store distribution, 1‑year profile) →
  install on the devices once. After that every Dart change is an OTA patch.
- Full Mac rebuild is only needed ~once a year (profile expiry) or when a native
  dependency changes.
- `shorebird init` already prepared the iOS side of the repo (`shorebird.yaml`
  is shared, one `app_id` covers both platforms). Nothing more to commit.
- No Mac? GitHub Actions macOS runner / MacinCloud / Codemagic all work.

**Not started** — needs Mac access once.

---

## 3. INTER_BOS recon

The owner wanted a **read‑only** connection from the app to "the INTER_BOS db"
that holds the register's live data, with "latest operations" as the headline
feature.

### What INTER_BOS is

The till PC (`hostname SERVER`) runs **MSSQL Server Express**, instance
`SERVER\SQLEXPRESS`, `sa` login (password is in
`C:\Digisoft\Reyoon\Digisoft.exe.config`; also the sync `.env`). Two databases:

- **DIGISOFT** (~80 MB) — back‑office master data (`TBLSTOKLAR` etc., what the
  existing product/price sync already uses).
- **INTER_BOS** (~4.7 GB) — the **live POS transaction DB** (a Profuture/Intaş
  "BOS" back‑office server). Updated within seconds of every sale. Single store
  (`SERVERCOMPANYID = 1`), single register (`Kasa_No = 1`), ~350 receipts and
  ~1000 line items per day.

Query it: `sqlcmd -S 'SERVER\SQLEXPRESS' -U sa -P <pw> -d INTER_BOS`
(sqlcmd at `C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\`).
Note: sqlcmd mangles Turkish characters on stdout (OEM codepage) — the nvarchar
data itself is fine, the node `mssql` driver reads it correctly.

### The tables that matter

| Table | Rows | Contents | Key |
|---|---|---|---|
| `BELGE` | 750k | Receipt headers — `Tarih`, `Kasa_No`, `Kasiyer_No`, `Belge_Tipi` (FIS/ZRP/XRP), `Belge_No` (daily #), `Toplam`, `Matrah`, `Kdv`, `Iptal` (1 = voided, ~11%), `Z_No`, precomputed `CASHTOTAL`/`CREDITTOTAL`/`DISCOUNTTOTAL`/`CANCELTOTAL`, `Notlar` | `ID` bigint, monotonic clustered PK |
| `HAREKET` | 2.7M | Receipt lines — `Belge_ID`, `Satir`, `Tip` (SAT=sale / IPT=void), `Barkod`, `Stok_Kodu`, `PLUNO`, `Adet`, `Fiyat` (unit price actually charged), `Tutar`, `Kdv`, `Ind_Miktar`, `Tarih`. `Urun_Adi` almost always NULL — names resolved from the app's own catalog. | `HAREKETID` bigint |
| `ODEME` | 641k | Payments — `Belge_ID`, `Tus_No` (0 = cash), `Kart_Tipi` (1/2/4/8 on cards, but **not** the scheme), `Kredi_Kart_No` (masked PAN like `535576******6491`), `Taksit` (installments, ~always 1), `Onay_No` (auth code), `Ref_No`, `Batch_No` (1041), `Terminal_No` (02097758), `AcquirerID` (12, one bank), `Tutar` | `ODEMEID` bigint |
| `SERVER_ZREPORT` | 3.9k | Daily Z — `ZNO`, `ZDATE`, `GIRO` (turnover), `INFO` (ntext). **`ZNO` is not reliably chronological** — the register's Z counter reset (fiscal‑unit swap) around 2026‑08‑11, so it went from ~3898 back to ~12. Sort by date/id, not `ZNO`. | `SERVERZREPORTID` |
| `FIYATGOR_HAREKET` | 59k | Price‑checker kiosk scans — barcode, price, did‑it‑sell. Live. |
| `POS_KREDI` | 3 | `Tus_No` → payment‑button label ("KREDİ KARTI" etc.) |

Dead ends checked so nobody repeats them: `SERVER_OPERATION` / `SERVER_MESSAGE`
are just the BOS↔POS sync protocol (not cashier actions); `POS_KASIYER*` tables
are empty; `KASAGIRIS_CIKIS` / `KASIYER_DEVIR` (cash drawer / shift settlement)
have 14 and 2 rows in ten years. Cashier names live in `DIGISOFT.TBLPERSONEL`
(Furkan, Ahmet) but there's no clean `Kasiyer_No → name` map; there are only two
cashier numbers.

Card scheme comes from the **BIN** (first digits of `Kredi_Kart_No`): `4…`→Visa,
`51–55` / `2221–2720`→Mastercard, `9792` / `65…`→Troy, `34` / `37`→Amex.
`Kart_Tipi` is **not** the scheme.

### The architecture decision

**Not** a direct MSSQL connection from Flutter:
- no production‑grade pure‑Dart MSSQL driver
- LAN‑only — the mobile apps would get nothing
- would bake `sa` into the app binary
- a native MSSQL FFI plugin breaks Shorebird patching

Instead: **the till‑PC daemon mirrors selected INTER_BOS data into Supabase**, and
the app reads it through the Supabase client it already uses. Works on every
platform, stays genuinely read‑only, new screens ship as patches. This became
section 4.

Memory: `barkod-interbos-kasa-db`.

---

## 4. The "İstatistik" tab

A desktop **İstatistik** tab (first shipped as "Kasa", renamed same day at the
owner's request — "Kasa" collided with "Kasaya Gönder"). Later also put on
mobile — see section 9.

### Supabase schema — `db/2026-08-29_kasa_mirror.sql` + `_kasa_helpers.sql` + `_kasa_dead_stock.sql`

Tables (all RLS‑enabled, **authenticated = SELECT only**, daemon writes with
service_role which bypasses RLS):

- `kasa_receipts` ← `BELGE` (`is_void = Iptal <> 0`, `card_brand` derived, see §6)
- `kasa_receipt_lines` ← `HAREKET`
- `kasa_payments` ← `ODEME` (masked PAN, scheme, auth code… added in §6)
- `kasa_zreports` ← `SERVER_ZREPORT`
- `kasa_product_sales_daily` — a (date, barcode) roll‑up, rebuilt by
  `rebuild_kasa_psd(days)`; powers "top products" and "dead stock"
- `kasa_price_mismatches` — till price ≠ catalog price (see below)
- `kasa_receipt_notes` — staff notes (see §5)
- `kasa_sync_state` — the daemon's high‑water marks (`belge_id`, `zreport_id`)

Functions: `rebuild_kasa_psd(int)` / `rebuild_kasa_psd_all()` (full‑rebuild
`DELETE` needs an explicit `WHERE` — Supabase runs sessions with `safeupdate`
on), `prune_kasa()`, `kasa_dead_stock(days, limit, require_history)`,
`kasa_top_products(from, to, limit)`.

Realtime publication: `kasa_receipts` + `kasa_price_mismatches` +
`kasa_receipt_notes`.

### The daemon module — `C:\Digisoft\SupabaseSync\src\kasaSync.ts` (not in this repo)

Wired into `index.ts` as an 8th `loopForever` (`KASA_POLL_INTERVAL_MS`, 5 s).

- Queries INTER_BOS by 3‑part name (`INTER_BOS.dbo.BELGE` — the service is
  connected to the `DIGISOFT` db, cross‑DB query on the same instance).
- Polls `BELGE` by `ID > cursor`, batches of 400; for each batch pulls all the
  `HAREKET` + `ODEME` rows for those `Belge_ID`s, upserts everything.
- Datetime: INTER_BOS stores local Turkey time (fixed UTC+3 since 2016). Reads
  it as `CONVERT(varchar, …, 126)` and appends `+03:00` → valid `timestamptz`.
- First run seeds ~90 days (sets the cursor to `MIN(ID) WHERE Tarih >= now-90d`).
- Every 5 min re‑scans the last 3 days of `BELGE` to catch void‑flag / close‑time
  changes (`Iptal` can flip after the fact).
- Every 6 h calls `prune_kasa()` (receipts/lines/payments kept 100 days, PSD 450,
  Z reports forever).
- Each tick calls `rebuild_kasa_psd(3)` for the recent window.
- **Price‑mismatch check** — for `SAT` lines sold in the last 48 h whose barcode
  matches `/^[1-9]\d{5,}$/` (excludes 1–5 digit department quick‑keys like `"9"` =
  TEMEL GIDA and `0…`‑prefixed stock codes), compares `HAREKET.Fiyat` to
  `products.price`. Any difference → a `kasa_price_mismatches` row. 48 h keeps it
  a real "the till is selling at a stale price right now" alarm; app‑initiated
  price changes reach the till within seconds so their false‑positive window is
  tiny.
- PostgREST upsert only writes the columns in the payload, so the re‑scan (which
  sends `BELGE` fields only) **preserves** `card_brand` — verified empirically.

The 90‑day backfill was run manually via a one‑off `src/kasaBackfillOnce.ts`
(shares the same cursor table, safe to run alongside the service): ~35k receipts,
~100k lines, ~31k payments, 91 Z reports in ~35 s.

### The app — `lib/kasa_repo.dart`, `lib/screens/istatistik_screen.dart`, `lib/widgets/sortable_table.dart`

Online‑only (no local cache, like messaging). Product names resolved from the
local catalog cache with a live `products` fallback.

`SortableTable<T>` — a reusable data table where **every column header
click‑sorts** (click again to reverse), striped rows, optional row tap, optional
per‑row tint. When the columns don't fit the width it scrolls horizontally
(added in §9 for mobile).

Six sections, `TabBar` at the top, a freshness chip ("kasa: 2 dk önce", green /
mustard if stale):

1. **Son İşlemler** — realtime receipt feed (`.stream()` on `kasa_receipts`),
   "load more" for older, row tap → a detail sheet (lines table + payments).
   Columns: Saat · Fiş No · Tutar · Ödeme · Ürün · Notlar · Durum.
2. **Günlük Özet** — a date picker; metric cards (Ciro, Fiş, Ort. Sepet, Satılan
   Ürün, Nakit, Kart, İndirim, İptal); **Kart Dağılımı** (a split bar by scheme);
   a custom hourly‑turnover bar chart (no chart library); top products (Seçili
   gün / Son 7 gün / Son 30 gün via `kasa_top_products`).
3. **İptaller** — voided receipts, 7/30/90‑day window.
4. **Fiyat Uyuşmazlığı** — the mismatch feed; realtime count pill on the tab;
   staff can mark rows resolved; "Çözülenleri de göster" toggle.
5. **Z Raporları** — daily Z list ordered by date (not `ZNO`), tap → the full
   report text.
6. **Ölü Stok** — `kasa_dead_stock` RPC: catalog products with no sale in
   14/30/60/90 days; "Geçmişte satılmış" = only ones that used to sell.

### Bugs fixed during the İstatistik build

- **Z reports mis‑ordered** — sorting by `z_no` put the pre‑reset ~Z3898 rows on
  top and buried the current Z16/Z15. Now `getZReports` orders by `id`, the table
  defaults to the Tarih column.
- **Spinner flash** — Son İşlemler and Fiyat Uyuşmazlığı recreated their realtime
  stream on every rebuild (and the detail sheet re‑fetched on every drag frame),
  so any parent `setState` re‑showed the spinner. Streams/futures are now held in
  `State` fields.
- **Price‑mismatch false positives** — early runs flagged `"9"` (TEMEL GIDA, a
  manual‑price department key, catalog "1") 8 times. Tightened the barcode regex
  and threaded `receipt_no` through.

Memory: `barkod-kasa-takip-feature`.

---

## 5. Fiş notes

The owner wanted to attach a note to any receipt, bound to the Fiş so it shows
**everywhere that receipt appears** (Son İşlemler, İptaller, the detail sheet)
— "if it's a cancelled one shown in multiple displays, all of them should show
it."

- `db/2026-08-29_kasa_receipt_notes.sql` — `kasa_receipt_notes` keyed by
  `belge_id` (the id `kasa_receipts` / lines / payments all share), one note per
  receipt, RLS `all authenticated`, in the realtime publication.
- `KasaRepo.watchReceiptNotes()` streams the whole (small) table as a
  `Map<belge_id, KasaReceiptNote>`; `setReceiptNote()` upserts (empty text →
  delete).
- `_IstatistikScreenState` holds one subscription and passes the map down.
- `_noteColumn` — a sortable "Notlar" column in **both** receipt tables
  (Son İşlemler replaced "Durum" width to fit; İptaller replaced the column that
  used to show the till's own `Notlar`). Tap the cell → an editor dialog.
- Detail sheet gets a note panel (its own `StreamBuilder`) with Not Ekle /
  Düzenle / Sil. The till's own `Notlar` is still shown, separately and muted.

Verified live: typed a note on Fiş 337, it appeared in the table immediately via
the realtime stream; a note set directly in the DB showed up bound to Fiş 339.

---

## 6. Card‑payment detail

Owner: "delete the İndirim column" and "can we see further into the Kard
payments".

- `db/2026-08-29_kasa_card_detail.sql` — adds `masked_pan`, `card_scheme`,
  `installments`, `auth_code`, `ref_no`, `batch_no`, `terminal_no`,
  `button_label` to `kasa_payments`, and `card_brand` to `kasa_receipts`.
- Daemon: pulls the extra `ODEME` columns + `POS_KREDI` button labels; a
  `cardScheme(pan)` BIN classifier; `receiptCardBrand()` computes a single brand
  per receipt (or "Karışık" / "Kart" / null).
- Last 30 days re‑backfilled with the new fields.
- App:
  - **İndirim column removed** from Son İşlemler.
  - The **Ödeme column** now shows the scheme — `Kart · Visa` /
    `Kart · Mastercard` / `Kart · Troy` / `Nakit` / `Karışık` — with an icon.
  - Detail sheet payments: `535576******6491 · onay 878161 · term. 02097758 ·
    batch 1041` per card payment.
  - **Günlük Özet → Kart Dağılımı**: card turnover split by scheme
    (Mastercard %63 · Visa %29 · Troy %7 on a typical day).
- "Durum" column left as‑is — it was correct, it just showed no voids because
  none fell in the visible window (voids cluster; the last one that day was at
  16:13, the feed shows the newest 60).

---

## 7. The desktop shortcut trap

The owner's `ÇÇM BARKOD` desktop shortcut (on the OneDrive‑redirected Masaüstü)
points at **`C:\src\CCM-Barkod-YENI\barkod_tarayici.exe`**, not
`build\windows\…`. `flutter build windows` does not touch that folder, so the
shortcut kept opening a stale build.

**After every Windows build:**
```powershell
Get-Process barkod_tarayici -EA SilentlyContinue | Stop-Process -Force
robocopy "C:\src\barkod\build\windows\x64\runner\Release" "C:\src\CCM-Barkod-YENI" /MIR /NP
```
(robocopy exit codes 0–7 = success; the PowerShell tool flags exit 1 as an error
but 1 just means "files copied".)

There's also an older `C:\Program Files (x86)\CCM-Barkod-Okuyucu-Windows\` from
Aug 23 that nothing on the desktop points at — ignore it.

Memory: `barkod-windows-build` (updated).

---

## 8. Nightly "Günlük Özet" push (FCM)

Owner: a nightly analytics summary pushed to a phone. First asked for WhatsApp,
then pivoted to "a general push notification, only 2 Android devices,
23:30".

### Why Firebase is involved at all

There is no "Supabase push". Delivering a notification to a backgrounded /
sleeping Android device goes through **FCM** — it's the transport built into
Android. Supabase does everything else (stores tokens, computes the summary,
schedules, decides recipients, sends the HTTP call); Firebase is just the last
hop. We use **only** `firebase_messaging` — no Firebase auth/db/functions.

### Firebase project (created via `firebase` CLI, `furkan.ozsoy09@gmail.com`)

`firebase-tools` installed globally. After the owner ran `firebase login`:

- `firebase projects:create ccm-barkod` → project #`212623614359`
- `firebase apps:create ANDROID` → app `1:212623614359:android:ef6ed8b0c253628aa6a4d2`
- `firebase apps:sdkconfig ANDROID … --out android/app/google-services.json`
- Minted an OAuth access token from the CLI's stored refresh token, used the IAM
  API to enable `fcm.googleapis.com` and to **create a service‑account key** for
  `firebase-adminsdk-fbsvc@ccm-barkod.iam.gserviceaccount.com`.

`google-services.json` **is committed** — its API key is package‑restricted and
ships in every APK, it's not a secret. The **service‑account key is not** — it's
a Supabase secret only.

### Supabase side (all done + tested)

- `db/2026-08-29_push_devices.sql` — `push_devices` (`fcm_token` PK, `staff_name`,
  `platform`, `enabled`, `last_seen_at`), RLS `all authenticated`.
  `kasa_day_summary_json(p_day date)` — the summary as jsonb (ciro, fiş, sepet,
  nakit, kart, `kart_marka`, iptal, en yoğun saat, `en_cok_satan[]`, açık
  uyuşmazlık, geçen hafta aynı gün cirosu).
- Edge function **`daily-summary-push`** (in the daemon's `supabase/functions/`,
  not tracked): reads the summary + `enabled` devices, mints an FCM v1 OAuth
  token by signing a JWT with the service account, POSTs to
  `fcm.googleapis.com/v1/projects/ccm-barkod/messages:send` per token, deletes
  `UNREGISTERED` / `INVALID_ARGUMENT` tokens. Deployed `--no-verify-jwt`; it
  checks `Authorization: Bearer <PUSH_CRON_SECRET>` itself.
- Secrets: `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT`, `PUSH_CRON_SECRET` (also
  stored in Vault as `push_cron_secret` for the cron).
- `pg_cron` + `pg_net` enabled. `db/2026-08-29_push_cron.sql` schedules
  `daily-summary-push` at `30 20 * * *` (20:30 UTC = 23:30 Türkiye), calling the
  function via `net.http_post` with the Vault secret.
- **Tested end‑to‑end**: fired the cron command manually from SQL → HTTP 200,
  message formatted correctly, the service‑account JWT → FCM auth works, a fake
  token got pruned. Sends `{sent:0}` until a real device is enabled.

Example message:
```
📊 29 Ağustos — Günlük Özet
💰 Ciro: 93.963 ₺ (geçen hafta 93.913 ₺, +%0)
🧾 333 fiş · ort. sepet 282 ₺ · 874 ürün
💵 Nakit 21.566 ₺   💳 Kart 72.397 ₺
     └ Mastercard %64 · Visa %28 · Troy %7 · Kart %1
❌ İptal: 28 fiş (22.043 ₺)
🔥 En yoğun saat: 15:00
🏆 TRANÇ · KIYMA · TEMEL GIDA
```

### App side

- `firebase_core` + `firebase_messaging`, google‑services gradle plugin
  (`android/settings.gradle.kts` + `android/app/build.gradle.kts` — works with
  the repo's AGP 9.1.0), `POST_NOTIFICATIONS` permission.
- `lib/push_service.dart` — Android only. `init()` (Firebase setup, permission
  prompt, background handler, token‑refresh listener — once); `syncToken()`
  registers the current token in `push_devices` and is called from
  `HomeShell.initState` **after** login (the `main()` attempt runs before the
  session exists and can't pass RLS).
- **Ayarlar → Bildirimler** (desktop) — a `push_devices` list with a per‑device
  enable switch. The owner turns on the 2 phones; every other device stays dark.

### Releases

The FCM packages are a native change → **`shorebird release android` `1.9.6+2029`**
(never distributed — superseded), then **`1.9.7+2030`** after a small token‑
registration refactor. `1.9.7` APK uploaded to `app-releases`, `app_releases`
updated.

**Still pending:** install `1.9.7` on the 2 phones → open once + grant the
notification permission → enable them in Ayarlar → fire a test push. The cron is
already live (sends 0 until then).

Memory: `barkod-daily-push`.

---

## 9. İstatistik on mobile + profile‑picker login

Owner, near the end: build the whole İstatistik menu on mobile, PIN‑gated
(`159951`, asked once then sticky like login); replace the name prompt at login
with a 5‑profile picker on mobile (Windows unchanged); the profiles just set the
per‑device display name under the same shared auth account.

- **`_mobileOrder`** gains `_idIstatistik` — İstatistik is now the 6th mobile
  bottom‑nav tab (`Icons.insights`).
- **`MobileIstatistikGate`** (in `istatistik_screen.dart`) — reads
  `SharedPreferences['istatistik_unlocked']`. If false, shows a numeric PIN
  field; `159951` sets the flag and swaps in `IstatistikScreen`. Sticky forever
  after (per device).
- **Login profile picker** — `login_screen.dart` `_promptForProfile()` (mobile) vs
  the existing `_promptForName()` text field (desktop, `isDesktopPlatform`). Five
  tappable rows: Ahmet / Osman / Ramazan / Furkan / Çoban (`kStaffProfiles`). The
  selection goes through the same `setStaffName()` → SharedPreferences (per
  device, as before). Still one shared Supabase auth account.
- **`SortableTable`** now measures its columns; when they exceed the available
  width it wraps the whole table (header + rows together) in a horizontal
  `SingleChildScrollView` and gives every column an explicit width
  (`width ?? flex * 108`). Desktop is unchanged (columns still `Expanded`).
- İstatistik top bar: the freshness chip moves below the tab row on mobile.

Intended as a `shorebird patch` on `1.9.7`, but **the patch was rejected** —
the new Material icons (`Icons.insights`, `Icons.lock_outline`, …) change the
tree‑shaken `MaterialIcons-Regular.otf` subset, and Shorebird patches don't carry
asset changes. So it went into a **full release `1.9.8+2031`** instead (1.9.7 was
never distributed, so nothing lost). New‑icon Dart changes always need a full
release, not a patch — worth remembering.

---

## 10. Build / release reference

### Android (Shorebird) — from `C:\src\barkod`

```bash
export PATH="/c/Program Files/Git/cmd:/c/shorebird/bin:/c/src/flutter/bin:$PATH"
export JAVA_HOME="C:\\Program Files\\Microsoft\\jdk-17.0.20.101-hotspot"
export ANDROID_SDK_ROOT="C:\\Android\\sdk"
export PUB_CACHE="C:\\pubcache"          # REQUIRED (jni + Turkish path)

flutter pub get
shorebird release android --artifact apk --target-platform android-arm64   # full release
shorebird patch   android --release-version=<v>                            # Dart/asset patch
```
Then upload the APK: `supabase storage cp <apk> ss:///app-releases/<name>
--content-type "application/vnd.android.package-archive" --experimental --linked`
(from the linked `scratchpad/supabase/` dir's parent), and
`update app_releases set version_code=…, version_name='…', apk_path='…',
changelog='…' where id=1;`.

### Windows — from `C:\src\barkod`

```powershell
$env:PATH = "C:\src\flutter\bin;C:\Program Files\Git\cmd;" + $env:PATH
$env:PUB_CACHE = "C:\pubcache"
flutter build windows --release
robocopy "C:\src\barkod\build\windows\x64\runner\Release" "C:\src\CCM-Barkod-YENI" /MIR /NP
```
(the old `C:\src\winbuild2.ps1` is broken — `vswhere` not found; `flutter doctor`
proves Flutter finds VS on its own, so build directly.)

### Supabase — from the linked scratchpad dir

```
supabase db query "…" --linked
supabase db query --file <sql> --linked
supabase functions deploy <name> --no-verify-jwt
supabase secrets set NAME=VALUE          # no --linked flag on `secrets`
```
`supabase projects api-keys` is blocked by the environment's classifier — the
service_role key is never needed in plaintext; the cron uses its own
`PUSH_CRON_SECRET`.

### Version history

| Version | versionCode | What |
|---|---|---|
| 1.9.4+27 | 2027 | last `--split-per-abi` release (pre‑session) |
| 1.9.5+2028 | 2028 | first Shorebird universal APK |
| 1.9.6+2029 | 2029 | FCM (never distributed) |
| **1.9.7+2030** | **2030** | FCM + push‑token fix — **current**; patched with mobile İstatistik + profile picker |

---

## 11. Commits

Trunk‑based, straight to `main` on `github.com/FrkanOzsoy/html-portfolio`.
Session commits, newest last:

```
Set up Shorebird OTA updates (Android), release 1.9.5+2028
docs: brief for the macOS builder agent (Shorebird iOS first release)
db: kasa (INTER_BOS POS) mirror tables + helper functions
Kasa: desktop tab for the till's live sales (INTER_BOS mirror)
Rename the "Kasa" tab to "İstatistik"
İstatistik: staff notes bound to each Fiş
İstatistik: cache the per-section streams/futures
İstatistik: card payment detail; drop İndirim column
db + docs: nightly Günlük Özet push (FCM) groundwork
Nightly Günlük Özet push — Flutter + FCM wiring (1.9.6+2029)
push_service: split init() from syncToken()
Bump to 1.9.7+2030
İstatistik on mobile (PIN-gated) + profile picker at login
docs: daily-summary-push progress
```

Untracked but on disk (same as the rest of that daemon, historically not in
git): `C:\Digisoft\SupabaseSync\src\kasaSync.ts`, `src/kasaBackfillOnce.ts`,
`supabase/functions/daily-summary-push/`.

---

## 12. Still open

- **Daily push**: install `1.9.7` on the 2 phones, grant notification permission,
  enable them in Ayarlar → Bildirimler, fire a test push. Cron already runs at
  23:30 (sends 0 until a device is enabled).
- **Mobile İstatistik**: never seen on a real phone / emulator (none available on
  this machine) — verified by code review + narrowing the Windows window to
  exercise the horizontal‑scroll path. Watch the first phone run.
- **iOS Shorebird**: needs a Mac once (`docs/shorebird-ios-setup.md`).
- **iOS daily push**: would need APNs — explicitly out of scope for now.
- The till‑PC daemon (`C:\Digisoft\SupabaseSync`) and its edge functions are
  still not version‑controlled anywhere.
- `docs/daily-summary-push.md` has the exact remaining commands.
