-- More detail on card payments (from INTER_BOS ODEME): masked PAN, card
-- scheme (derived from the BIN), installments, auth code, batch/terminal for
-- reconciliation, and the payment-button label (POS_KREDI).
alter table public.kasa_payments add column if not exists masked_pan     text;
alter table public.kasa_payments add column if not exists card_scheme    text;   -- Visa / Mastercard / Troy / Amex / ...
alter table public.kasa_payments add column if not exists installments   smallint;
alter table public.kasa_payments add column if not exists auth_code      text;   -- Onay_No
alter table public.kasa_payments add column if not exists ref_no         text;   -- Ref_No
alter table public.kasa_payments add column if not exists batch_no       integer;
alter table public.kasa_payments add column if not exists terminal_no    text;
alter table public.kasa_payments add column if not exists button_label   text;   -- POS_KREDI.Info for Tus_No

-- A per-receipt summary of the card scheme(s) used, so the receipt list can
-- show "Kart · Visa" without joining payments. Single scheme name, or
-- 'Karışık' when a receipt mixes schemes, or null when no card payment.
alter table public.kasa_receipts add column if not exists card_brand text;

create index if not exists kasa_payments_scheme_idx on public.kasa_payments (card_scheme);
create index if not exists kasa_receipts_brand_idx  on public.kasa_receipts (card_brand);
