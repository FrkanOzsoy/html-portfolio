-- Widen the field CHECK on product_pending_changes so a staged *deletion*
-- ('__delete__' sentinel, see DataRepo.kDeleteField / stageDelete) can be
-- queued in Kasaya Gönder like any other change. The till-PC never reads
-- this table (it processes product_delete_requests); this only affects the
-- app's own staging.
alter table public.product_pending_changes drop constraint if exists product_pending_changes_field_check;
alter table public.product_pending_changes add constraint product_pending_changes_field_check
  check (field = any (array['stockname','stockunit','depno','price','__delete__']));
