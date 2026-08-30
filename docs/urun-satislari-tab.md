# Ürün Satışları Tab & Build Guide

## Overview

The "Ölü Stok" tab in İstatistik has been evolved into **"Ürün Satışları"** (Product Sales explorer) on both Windows desktop and mobile (PIN-gated: 159951).

### Key Features:
- **Timeline Presets:** Bugün, Son 7 gün, Son 30 gün, Son 90 gün, Bu Ay, Geçen Ay, and custom date range picker (`showDateRangePicker`).
- **KDV / Reyon Filter:** Dynamic dropdown populated from distinct department codes (`depno`).
- **Sale Status Mode:** Tümü / Satılanlar / Satılmayanlar (Ölü Stok) + "Geçmişte satılmış" filter.
- **Client-side Search:** Filter visible rows instantly by product name or barcode.
- **Interactive Sortable Table:** Click-to-sort on every column: Ürün, Fiyat, Reyon (with KDV rate), Satılan Adet, Ciro, İşlem, Son Satış.
- **Summary Strip:** Realtime aggregated summary of filtered rows (Count · Total Units · Revenue · Transactions).
- **Backend RPC:** `kasa_product_sales_report(p_from, p_to, p_depno, p_include_unsold, p_limit)` in `db/2026-08-29_product_sales_report.sql` (already applied to Supabase).

---

## How to Deploy on the Till PC (`hostname SERVER` / `C:\src\barkod`)

### Step 1: Pull Latest Commits
```bash
cd C:\src\barkod
git pull origin main
```

### Step 2: Update Windows Desktop Build
```powershell
$env:PATH = "C:\src\flutter\bin;C:\Program Files\Git\cmd;" + $env:PATH
$env:PUB_CACHE = "C:\pubcache"

# Stop existing running instance
Get-Process barkod_tarayici -EA SilentlyContinue | Stop-Process -Force

# Build release
flutter build windows --release

# Mirror output to the shortcut directory
robocopy "C:\src\barkod\build\windows\x64\runner\Release" "C:\src\CCM-Barkod-YENI" /MIR /NP
```

### Step 3: Deploy Android — full release, NOT a patch

This change added new Material icons (`Icons.date_range`, `Icons.clear`,
`Icons.arrow_drop_down`), which change the tree-shaken `MaterialIcons-Regular.otf`
subset. Shorebird patches don't carry asset changes, so `shorebird patch` aborts
with "app contains asset changes". Cut a full release.

```bash
export PATH="/c/Program Files/Git/cmd:/c/shorebird/bin:/c/src/flutter/bin:$PATH"
export JAVA_HOME="C:\\Program Files\\Microsoft\\jdk-17.0.20.101-hotspot"
export ANDROID_SDK_ROOT="C:\\Android\\sdk"
export PUB_CACHE="C:\\pubcache"

# bump pubspec version (e.g. 1.9.9+2032), then:
shorebird release android --artifact apk --target-platform android-arm64

supabase storage cp build/app/outputs/flutter-apk/app-release.apk \
  ss:///app-releases/ccm-barkod-okuyucu-v1.9.x.apk \
  --content-type "application/vnd.android.package-archive" --experimental --linked
# then: update app_releases set version_code=…, version_name='…', apk_path='…', changelog='…' where id=1;
```

Shipped as **1.9.9+2032** (2026-08-30), together with the desktop "Düzenle"
button in Ürün Ara.
