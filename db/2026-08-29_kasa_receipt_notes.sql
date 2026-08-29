-- Staff notes bound to a till receipt (Fiş). One note per receipt, keyed by
-- belge_id (the id HAREKET/ODEME/kasa_receipts all share), so the same note
-- shows wherever that receipt appears -- Son İşlemler, İptaller, the detail
-- sheet. Daemon-independent: kasaSync never touches this table.
create table if not exists public.kasa_receipt_notes (
  belge_id    text primary key,
  note        text not null,
  updated_by  text,
  updated_at  timestamptz not null default now()
);

alter table public.kasa_receipt_notes enable row level security;

drop policy if exists kasa_receipt_notes_all_authenticated on public.kasa_receipt_notes;
create policy kasa_receipt_notes_all_authenticated
  on public.kasa_receipt_notes for all to authenticated
  using (true) with check (true);

-- realtime: a note added on one client shows on the others live
do $$
begin
  alter publication supabase_realtime add table public.kasa_receipt_notes;
exception when duplicate_object then null;
end $$;
