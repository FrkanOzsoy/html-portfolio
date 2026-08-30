-- Allow 'barcode' as an editable field. A barcode change replaces OLD with
-- NEW for the same product (Digisoft STOKKODU): the request row carries
-- barcode = OLD, new_value = NEW. The till-PC daemon (fieldSync.ts) updates
-- TBLSTOK_BARKODLAR / TBLSTOKLAR, re-syncs, and cleans up the stale OLD rows
-- in Supabase (products / list_items).

alter table public.product_pending_changes
  drop constraint if exists product_pending_changes_field_check;
alter table public.product_pending_changes
  add constraint product_pending_changes_field_check
  check (field = any (array['stockname','stockunit','depno','price','barcode','__delete__']));

alter table public.product_field_update_requests
  drop constraint if exists product_field_update_requests_field_check;
alter table public.product_field_update_requests
  add constraint product_field_update_requests_field_check
  check (field = any (array['stockname','stockunit','depno','reyon','kasadepid','barcode']));
