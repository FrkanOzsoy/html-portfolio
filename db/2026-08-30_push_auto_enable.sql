-- Auto-enable the nightly "Günlük Özet" push for devices that log in as one
-- of a small set of staff names, so a new phone (e.g. Ahmet's) starts getting
-- the push the first time it registers -- without the owner having to open
-- Ayarlar → Bildirimler and flip a switch.
--
-- INSERT-only trigger: it fires on first registration of an fcm_token. Every
-- later app launch re-registers via ON CONFLICT DO UPDATE, which does NOT fire
-- this trigger -- so if the owner turns a device off in Ayarlar, it stays off.

create table if not exists public.push_notify_names (
  name text primary key
);

insert into public.push_notify_names (name) values ('Furkan'), ('Ahmet')
  on conflict (name) do nothing;

alter table public.push_notify_names enable row level security;
drop policy if exists push_notify_names_read on public.push_notify_names;
create policy push_notify_names_read on public.push_notify_names
  for select to authenticated using (true);

create or replace function public.push_devices_auto_enable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not new.enabled
     and new.staff_name is not null
     and exists (select 1 from public.push_notify_names n where n.name = new.staff_name)
  then
    new.enabled := true;
  end if;
  return new;
end;
$$;

drop trigger if exists push_devices_auto_enable_tg on public.push_devices;
create trigger push_devices_auto_enable_tg
  before insert on public.push_devices
  for each row execute function public.push_devices_auto_enable();
