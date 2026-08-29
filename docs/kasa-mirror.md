# Kasa (INTER_BOS POS) mirror

Read-only view, in the app, of the register's live sales. The app never
writes to the till; the one mutation is a review flag
(`kasa_price_mismatches.resolved`).

## Where the data comes from

The till PC (`hostname SERVER`) runs MSSQL Express, instance
`SERVER\SQLEXPRESS`, database **INTER_BOS** — a Profuture/Intaş "BOS" POS
back-office DB. A new module in the till-PC daemon,
`C:\Digisoft\SupabaseSync\src\kasaSync.ts` (not tracked in this repo, like
the rest of that daemon), polls it every ~5 s by high-water-mark id and
upserts into Supabase with the service_role key:

| INTER_BOS | → Supabase | notes |
|---|---|---|
| `BELGE`          | `kasa_receipts`        | receipt headers; `is_void` = `Iptal <> 0` |
| `HAREKET`        | `kasa_receipt_lines`   | line items; `line_type` SAT/IPT |
| `ODEME`          | `kasa_payments`        | `method` = daemon's nakit/kart/diger guess |
| `SERVER_ZREPORT` | `kasa_zreports`        | daily Z, `turnover` = GIRO |
| (derived)        | `kasa_product_sales_daily` | rebuilt by `rebuild_kasa_psd` RPC |
| (derived)        | `kasa_price_mismatches` | till price ≠ catalog price, last 48 h only |
| (cursors)        | `kasa_sync_state`      | `belge_id`, `zreport_id` high-water marks |

Datetimes: INTER_BOS stores local Turkey time (fixed UTC+3 since 2016); the
daemon reads them as `CONVERT(varchar,…,126)` and appends `+03:00`.

First run backfills ~90 days, then prunes receipts/lines/payments past
100 days (`prune_kasa`, every 6 h). `kasa_product_sales_daily` is kept
~450 days for the "dead stock" view; Z reports are never pruned. Voided /
reopened receipts are re-scanned for the last 3 days every 5 minutes.

`db/2026-08-29_kasa_mirror.sql` — tables + RLS (authenticated SELECT only,
plus UPDATE on `kasa_price_mismatches`) + realtime on `kasa_receipts` and
`kasa_price_mismatches`.
`db/2026-08-29_kasa_helpers.sql` — `rebuild_kasa_psd(_all)`, `prune_kasa`.
`db/2026-08-29_kasa_dead_stock.sql` — `kasa_dead_stock`, `kasa_top_products` RPCs.

## App side

Desktop-only **"Kasa"** tab (`HomeShell._idKasa`, after "Kasaya Gönder").
`lib/kasa_repo.dart` + `lib/screens/kasa_screen.dart`, six sections, every
table sortable by any column (`lib/widgets/sortable_table.dart`):

1. **Son İşlemler** — live receipt feed (realtime), tap → lines + payments.
2. **Günlük Özet** — per-day: ciro, fiş, ort. sepet, nakit/kart, indirim,
   iptal, satılan ürün; hourly turnover bars; top products (day / 7 g / 30 g).
3. **İptaller** — voided receipts, 7/30/90-day window.
4. **Fiyat Uyuşmazlığı** — till charged ≠ catalog price (last 48 h of sales;
   1–5 digit "barcodes" and `0…`-prefixed stock codes excluded — those are
   manual-price department keys). Realtime badge on the tab. Staff can mark
   a row resolved.
5. **Z Raporları** — daily Z list, tap → the report's full text.
6. **Ölü Stok** — catalog products with no sale in 14/30/60/90 days
   (`kasa_dead_stock` RPC). "Geçmişte satılmış" = only ones that used to sell.

Product names are resolved from the local catalog cache (fully synced on
desktop) with a live `products` fallback.

## Restarting the daemon after a code change

`kasaSync.ts` is compiled with `npm run build` (→ `dist/`) and picked up on
the next service restart:

```powershell
# elevated PowerShell
Restart-Service DigisoftSupabaseSync
```

The service's own cursors live in `kasa_sync_state`, so a restart resumes
where it left off — it does **not** re-backfill.
`src/kasaBackfillOnce.ts` is a standalone catch-up runner
(`npx tsx src/kasaBackfillOnce.ts`) that shares the same cursors, for use
when the service can't be restarted immediately.
