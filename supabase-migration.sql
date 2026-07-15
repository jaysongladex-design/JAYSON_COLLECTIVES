-- =============================================================================
--  GLADEX COLLECTIVES -> SUPABASE
--  Run ONCE: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
--
--  Creates : collectives / collective_payments / collective_sales / profiles
--  Security: RLS on everything. The anon key gets NOTHING (it currently reads
--            your whole booking table - do not repeat that mistake here).
--            Regular users may only ADD payments + slot sales.
--            Admins may do everything. Same rules as the back-office app,
--            but enforced by the database instead of by JavaScript.
--  Status  : PENDING/FINISHED are computed from travel_end, exactly like the app.
--            Only VOID is stored (the `voided` flag).
-- =============================================================================

begin;

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------- 1. TABLES
create table if not exists public.collectives (
  id                           uuid primary key default gen_random_uuid(),
  package                      text not null,
  tour_code                    text,
  travel_raw                   text,          -- "5/16/2026 - 5/21/2026" as typed
  travel_start                 date,
  travel_end                   date,          -- drives PENDING vs FINISHED
  holding_date                 date,
  sold_out_date                date,
  amount_per_pax               numeric(14,2),
  exp_profit_per_person        numeric(14,2),
  est_profit_per_departure     numeric(14,2),
  total_cost                   numeric(14,2) not null default 0,
  slot                         integer not null default 0,   -- paid slots
  foc                          integer not null default 0,   -- free-of-charge slots
  remaining_balance_to_collect numeric(14,2),
  voided                       boolean not null default false,
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),
  unique (package, tour_code, travel_raw)
);

create table if not exists public.collective_payments (
  id            uuid primary key default gen_random_uuid(),
  collective_id uuid not null references public.collectives(id) on delete cascade,
  paid_on       date,
  amount        numeric(14,2) not null check (amount > 0),
  note          text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);
create index if not exists idx_payments_collective on public.collective_payments(collective_id);

create table if not exists public.collective_sales (
  id            uuid primary key default gen_random_uuid(),
  collective_id uuid not null references public.collectives(id) on delete cascade,
  sold_on       date,
  slots         integer not null default 0 check (slots > 0),
  amount        numeric(14,2) not null default 0 check (amount >= 0),
  note          text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);
create index if not exists idx_sales_collective on public.collective_sales(collective_id);

-- users + roles (mirrors the app's Admin / Regular)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       text not null default 'regular' check (role in ('admin','regular')),
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
  language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$fn$;

-- ------------------------------------------------------ 2. DERIVED SUMMARY
-- Same formulas as the app. paid/collected/slots always come from the logs.
create or replace view public.collective_summary as
select
  c.id, c.package, c.tour_code, c.travel_raw, c.travel_start, c.travel_end,
  c.holding_date, c.sold_out_date, c.total_cost, c.slot, c.foc, c.voided,
  case when c.voided then 'VOID'
       when c.travel_end is not null and c.travel_end < current_date then 'FINISHED'
       else 'PENDING' end                                   as status,
  (c.slot + c.foc)                                          as total_slots,
  coalesce(p.paid, 0)                                       as current_payment,
  round(c.total_cost - coalesce(p.paid, 0), 2)              as balance_payable,
  coalesce(s.slots_sold, 0)                                 as slot_sold,
  (c.slot + c.foc) - coalesce(s.slots_sold, 0)              as remaining_slot,
  coalesce(s.collected, 0)                                  as collected,
  round(coalesce(s.collected, 0) - coalesce(p.paid, 0), 2)  as profit,
  case when c.total_cost > 0
       then round(((coalesce(s.collected,0) - coalesce(p.paid,0)) / c.total_cost) * 100, 2)
  end                                                       as roi_pct
from public.collectives c
left join (select collective_id, sum(amount) as paid
             from public.collective_payments group by 1) p on p.collective_id = c.id
left join (select collective_id, sum(slots) as slots_sold, sum(amount) as collected
             from public.collective_sales group by 1) s on s.collective_id = c.id;

-- --------------------------------------------------------------- 3. SECURITY
alter table public.collectives         enable row level security;
alter table public.collective_payments enable row level security;
alter table public.collective_sales    enable row level security;
alter table public.profiles            enable row level security;

-- the anon key must never see cost/margin data
revoke all on public.collectives, public.collective_payments, public.collective_sales from anon;
revoke all on public.collective_summary from anon;

drop policy if exists p_col_read   on public.collectives;
drop policy if exists p_col_write  on public.collectives;
drop policy if exists p_pay_read   on public.collective_payments;
drop policy if exists p_pay_insert on public.collective_payments;
drop policy if exists p_pay_upd    on public.collective_payments;
drop policy if exists p_pay_del    on public.collective_payments;
drop policy if exists p_sal_read   on public.collective_sales;
drop policy if exists p_sal_insert on public.collective_sales;
drop policy if exists p_sal_upd    on public.collective_sales;
drop policy if exists p_sal_del    on public.collective_sales;
drop policy if exists p_prof_self  on public.profiles;
drop policy if exists p_prof_admin on public.profiles;

-- collectives: any signed-in user reads; only admins change (this is the frozen Details)
create policy p_col_read  on public.collectives for select to authenticated using (true);
create policy p_col_write on public.collectives for all    to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- payments: signed-in may read + ADD (the Regular user's job); only admins edit/delete
create policy p_pay_read   on public.collective_payments for select to authenticated using (true);
create policy p_pay_insert on public.collective_payments for insert to authenticated with check (true);
create policy p_pay_upd    on public.collective_payments for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy p_pay_del    on public.collective_payments for delete to authenticated using (public.is_admin());

-- slot sales: same shape as payments
create policy p_sal_read   on public.collective_sales for select to authenticated using (true);
create policy p_sal_insert on public.collective_sales for insert to authenticated with check (true);
create policy p_sal_upd    on public.collective_sales for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy p_sal_del    on public.collective_sales for delete to authenticated using (public.is_admin());

-- profiles: read your own; admins manage everyone
create policy p_prof_self  on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy p_prof_admin on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------------ 4. DATA
-- Idempotent: re-running replaces the rows instead of duplicating them.
delete from public.collectives;   -- cascades to payments + sales

insert into public.collectives
  (package, tour_code, travel_raw, travel_start, travel_end, holding_date, sold_out_date,
   amount_per_pax, exp_profit_per_person, est_profit_per_departure, total_cost, slot, foc,
   remaining_balance_to_collect, voided)
values
  ('6D4N Korea Nami Island', 'JTKR1B1  - A', '5/16/2026 - 5/21/2026', '2026-05-16'::date, '2026-05-21'::date, '2026-02-12'::date, '2026-03-04'::date, 31187.00, 4000.00, 64000.00, 514200.00, 15, 1, null, false),
  ('6D4N Korea Nami Island', 'JTKR1B1  - B', '9/11/2026 - 9/16/2026', '2026-09-11'::date, '2026-09-16'::date, '2026-02-12'::date, null, 33297.00, 4000.00, 64000.00, 424475.96, 15, 1, null, false),
  ('6D4N Korea Nami Island', 'JTKR1B1  - C', '10/11/2026 - 10/16/2026', '2026-10-11'::date, '2026-10-16'::date, '2026-02-12'::date, null, 28298.00, 4000.00, 64000.00, 486630.84, 15, 1, null, false),
  ('6D4N Korea Nami Island', 'JTKR1B1  - D', '11/15/2026 - 11/20/2026', '2026-11-15'::date, '2026-11-20'::date, '2026-02-12'::date, null, 30254.00, 4000.00, 64000.00, 476010.84, 15, 1, null, false),
  ('6D4N Korea Nami Island', 'JTKR1B1  - E', '12/12/2026 - 12/17/2026', '2026-12-12'::date, '2026-12-17'::date, '2026-02-12'::date, null, 31193.00, 4000.00, 64000.00, 476010.84, 15, 1, null, false),
  ('6D4N Korea Nami Island', 'JTKR1B1  - F', '01/19/2027 - 01/24/2027', '2027-01-19'::date, '2027-01-24'::date, '2026-07-02'::date, null, 31963.00, 4000.00, 128000.00, 1010848.00, 31, 1, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV12B2 - A', '2/28/2026 - 3/3/2026', '2026-02-28'::date, '2026-03-03'::date, '2025-07-07'::date, '2025-08-27'::date, 20568.00, 2500.00, 62500.00, 514200.00, 25, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV12B2 - B', '3/28/2026 - 3/31/2026', '2026-03-28'::date, '2026-03-31'::date, '2025-07-07'::date, '2025-11-28'::date, 20568.00, 2500.00, 62500.00, 514200.00, 25, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV12B2 - C', '4/25/2026 - 4/28/2026', '2026-04-25'::date, '2026-04-28'::date, '2025-07-07'::date, '2026-04-05'::date, 20568.00, 2500.00, 62500.00, 514200.00, 25, 0, null, false),
  ('5D3N Da Nang Charter (VJ VietJet)', 'UOV24B2 - A', '1/14/2026 - 1/17/2026', '2026-01-14'::date, '2026-01-17'::date, '2025-10-23'::date, '2025-11-25'::date, 21984.00, 3500.00, 87500.00, 549600.00, 25, 0, null, false),
  ('5D3N Da Nang Charter (VJ VietJet)', 'UOV24B2 - B', '3/4/2026 - 3/7/2026', '2026-03-04'::date, '2026-03-07'::date, '2025-10-23'::date, '2025-12-16'::date, 21984.00, 3500.00, 87500.00, 549600.00, 25, 0, null, false),
  ('5D3N Da Nang Charter (VJ VietJet)', 'UOV24B2 - C', '4/22/2026 - 4/25/2026', '2026-04-22'::date, '2026-04-25'::date, '2025-10-23'::date, '2026-03-05'::date, 21984.00, 3500.00, 87500.00, 329760.00, 25, 0, null, false),
  ('5D3N Da Nang Charter (VJ VietJet)', 'UOV24B2 - D', '5/27/2026 - 5/30/2026', '2026-05-27'::date, '2026-05-30'::date, '2025-10-23'::date, '2026-05-21'::date, 21984.00, 3500.00, 87500.00, 549600.00, 25, 0, null, false),
  ('5D3N Da Nang Charter (VJ VietJet)', 'UOV24B2 - E', '6/10/2026 - 6/13/2026', '2026-06-10'::date, '2026-06-13'::date, '2025-10-23'::date, '2026-05-01'::date, 21984.00, 3500.00, 87500.00, 549600.00, 25, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - A', '7/18/2026 - 7/21/2026', '2026-07-18'::date, '2026-07-21'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - B', '8/15/2026 - 8/18/2026', '2026-08-15'::date, '2026-08-18'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - C', '9/19/2026 - 9/22/2026', '2026-09-19'::date, '2026-09-22'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - D', '10/24/2026 - 10/27/2026', '2026-10-24'::date, '2026-10-27'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - E', '11/21/2026 - 11/24/2026', '2026-11-21'::date, '2026-11-24'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('4D3N Da Nang Charter (5J Cebu Pacific)', 'UOV15B2 - F', '12/12/2026 - 12/15/2026', '2026-12-12'::date, '2026-12-15'::date, '2026-01-26'::date, null, 20568.00, 2500.00, 40000.00, 308520.00, 16, 0, null, false),
  ('5D3N Da Nang (VJ VietJet)', 'UOV42B1 - A', '11/11/2026 - 11/14/2026', '2026-11-11'::date, '2026-11-14'::date, '2026-06-24'::date, null, 24170.00, 3500.00, 112000.00, 805440.00, 31, 1, null, false),
  ('5D3N Da Nang (VJ VietJet)', 'UOV42B1 - B', '11/18/2026 - 11/21/2026', '2026-11-18'::date, '2026-11-21'::date, '2026-06-24'::date, null, 24170.00, 3500.00, 52500.00, 308520.00, 15, 0, null, false),
  ('5D3N Da Nang (VJ VietJet)', 'UOV42B1 - C', '12/9/2026 - 12/12/2026', '2026-12-09'::date, '2026-12-12'::date, '2026-06-24'::date, null, 24170.00, 3500.00, 112000.00, 863552.00, 31, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - A', '7/3/2026 - 7/6/2026', '2026-07-03'::date, '2026-07-06'::date, '2026-03-24'::date, '2026-05-28'::date, 21016.00, 3000.00, 48000.00, 311189.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - B', '7/10/2026 - 7/13/2026', '2026-07-10'::date, '2026-07-13'::date, '2026-03-24'::date, '2026-06-16'::date, 20484.00, 3000.00, 48000.00, 368489.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - C', '7/17/2026 - 7/20/2026', '2026-07-17'::date, '2026-07-20'::date, '2026-03-24'::date, '2026-06-26'::date, null, 3000.00, 48000.00, 305049.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - D', '7/24/2026 - 7/27/2026', '2026-07-24'::date, '2026-07-27'::date, '2026-03-24'::date, null, 19417.00, 3000.00, 48000.00, 307239.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - E', '8/7/2026 - 8/10/2026', '2026-08-07'::date, '2026-08-10'::date, '2026-03-24'::date, null, null, 3000.00, 48000.00, 291239.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - F', '8/14/2026 - 8/17/2026', '2026-08-14'::date, '2026-08-17'::date, '2026-03-24'::date, null, 19951.00, 3000.00, 48000.00, 299239.92, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - G', '11/13/2026 - 11/16/2026', '2026-11-13'::date, '2026-11-16'::date, '2026-07-06'::date, null, null, 3000.00, 48000.00, 195906.56, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - H', '11/19/2026 - 11/22/2026', '2026-11-19'::date, '2026-11-22'::date, '2026-07-06'::date, null, null, 3000.00, 48000.00, 215458.56, 15, 1, null, false),
  ('4D3N Bangkok Blockings', 'SBBK1B2 - I', '12/11/2026 - 12/14/2026', '2026-12-11'::date, '2026-12-14'::date, '2026-07-06'::date, null, null, 3000.00, 48000.00, 231458.56, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - A', '7/3/2026 - 7/6/2026', '2026-07-03'::date, '2026-07-06'::date, '2026-03-24'::date, '2026-06-24'::date, null, 3000.00, 48000.00, 354551.22, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - B', '7/10/2026 - 7/13/2026', '2026-07-10'::date, '2026-07-13'::date, '2026-03-24'::date, null, null, 3000.00, 48000.00, 438371.82, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - C', '7/17/2026 - 7/20/2026', '2026-07-17'::date, '2026-07-20'::date, '2026-03-24'::date, null, 27112.29, 3000.00, 48000.00, 439755.62, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - D', '7/24/2026 - 7/27/2026', '2026-07-24'::date, '2026-07-27'::date, '2026-03-24'::date, '2026-06-30'::date, null, 3000.00, 48000.00, 311229.32, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - E', '8/7/2026 - 8/10/2026', '2026-08-07'::date, '2026-08-10'::date, '2026-03-24'::date, '2026-05-22'::date, null, 3000.00, 48000.00, 293629.32, 15, 1, null, false),
  ('4D3N Hong Kong Blockings', 'CNHK1B1 - F', '8/14/2026 - 8/17/2026', '2026-08-14'::date, '2026-08-17'::date, '2026-03-24'::date, '2026-06-08'::date, null, 3000.00, 48000.00, 293629.32, 15, 1, null, false),
  ('4D3N Singapore Blockings', 'TVSG1B1 - A', '7/10/2026 - 7/13/2026', '2026-07-10'::date, '2026-07-13'::date, '2026-03-24'::date, '2026-06-30'::date, 26537.00, 3000.00, 48000.00, 444986.84, 15, 1, null, false),
  ('4D3N Singapore Blockings', 'TVSG1B1 - B', '7/24/2026 - 7/27/2026', '2026-07-24'::date, '2026-07-27'::date, '2026-03-24'::date, '2026-07-02'::date, 25149.00, 3000.00, 48000.00, 377227.20, 15, 1, null, false),
  ('ADORA CRUISE MNL - JAPAN', 'UOAC2B2', '12/21/2026 - 12/27/2026', '2026-12-21'::date, '2026-12-27'::date, '2026-03-06'::date, '2026-04-16'::date, 42299.10, 3699.90, 103597.20, 1108676.70, 28, 0, null, false),
  ('ADORA CRUISE MNL - JAPAN', 'UOAC2B2', '12/27/2026 - 01/02/2027', '2026-12-27'::date, '2027-01-02'::date, '2026-03-06'::date, '2026-04-09'::date, 42299.10, 3699.90, 59198.40, 777264.32, 16, 0, null, false);

-- Opening payment per departure = the workbook's CURRENT PAYMENT TO SUPPLIER,
-- so Balance Payable reconciles to your file from day one.
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-02-12'::date, 514200.00, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - A' and travel_raw = '5/16/2026 - 5/21/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-02-12'::date, 58560.00, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - B' and travel_raw = '9/11/2026 - 9/16/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-02-12'::date, 77206.00, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - C' and travel_raw = '10/11/2026 - 10/16/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-02-12'::date, 71590.75, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - D' and travel_raw = '11/15/2026 - 11/20/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-02-12'::date, 71590.75, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - E' and travel_raw = '12/12/2026 - 12/17/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-07-02'::date, 310000.00, 'Opening payment (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - F' and travel_raw = '01/19/2027 - 01/24/2027';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-07-07'::date, 514200.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - A' and travel_raw = '2/28/2026 - 3/3/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-07-07'::date, 514200.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - B' and travel_raw = '3/28/2026 - 3/31/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-07-07'::date, 514200.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - C' and travel_raw = '4/25/2026 - 4/28/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-10-23'::date, 549600.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - A' and travel_raw = '1/14/2026 - 1/17/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-10-23'::date, 549600.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - B' and travel_raw = '3/4/2026 - 3/7/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-10-23'::date, 329760.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - C' and travel_raw = '4/22/2026 - 4/25/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-10-23'::date, 549600.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - D' and travel_raw = '5/27/2026 - 5/30/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2025-10-23'::date, 549600.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - E' and travel_raw = '6/10/2026 - 6/13/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - A' and travel_raw = '7/18/2026 - 7/21/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - B' and travel_raw = '8/15/2026 - 8/18/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - C' and travel_raw = '9/19/2026 - 9/22/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - D' and travel_raw = '10/24/2026 - 10/27/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - E' and travel_raw = '11/21/2026 - 11/24/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-01-26'::date, 150000.00, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - F' and travel_raw = '12/12/2026 - 12/15/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-06-24'::date, 151010.40, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang (VJ VietJet)' and tour_code = 'UOV42B1 - A' and travel_raw = '11/11/2026 - 11/14/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-06-24'::date, 174170.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang (VJ VietJet)' and tour_code = 'UOV42B1 - B' and travel_raw = '11/18/2026 - 11/21/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-06-24'::date, 151010.00, 'Opening payment (imported from file)' from public.collectives where package = '5D3N Da Nang (VJ VietJet)' and tour_code = 'UOV42B1 - C' and travel_raw = '12/9/2026 - 12/12/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 311189.92, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - A' and travel_raw = '7/3/2026 - 7/6/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 368489.92, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - B' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 305049.92, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - C' and travel_raw = '7/17/2026 - 7/20/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 61046.98, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - D' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 65846.98, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - E' and travel_raw = '8/7/2026 - 8/10/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 63446.98, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - F' and travel_raw = '8/14/2026 - 8/17/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-07-06'::date, 58771.97, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - G' and travel_raw = '11/13/2026 - 11/16/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 354551.22, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - A' and travel_raw = '7/3/2026 - 7/6/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 438371.82, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - B' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 439755.62, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - C' and travel_raw = '7/17/2026 - 7/20/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 159084.32, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - D' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 141484.32, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - E' and travel_raw = '8/7/2026 - 8/10/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 141484.32, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - F' and travel_raw = '8/14/2026 - 8/17/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 444986.84, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Singapore Blockings' and tour_code = 'TVSG1B1 - A' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-24'::date, 272388.81, 'Opening payment (imported from file)' from public.collectives where package = '4D3N Singapore Blockings' and tour_code = 'TVSG1B1 - B' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-06'::date, 213414.32, 'Opening payment (imported from file)' from public.collectives where package = 'ADORA CRUISE MNL - JAPAN' and tour_code = 'UOAC2B2' and travel_raw = '12/21/2026 - 12/27/2026';
insert into public.collective_payments (collective_id, paid_on, amount, note) select id, '2026-03-06'::date, 121939.20, 'Opening payment (imported from file)' from public.collectives where package = 'ADORA CRUISE MNL - JAPAN' and tour_code = 'UOAC2B2' and travel_raw = '12/27/2026 - 01/02/2027';

-- Opening sale per departure = the workbook's SLOT SOLD + COLLECTED FROM PAX.
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-02-12'::date, 16, 632192.00, 'Opening sale (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - A' and travel_raw = '5/16/2026 - 5/21/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-02-12'::date, 14, 524989.00, 'Opening sale (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - B' and travel_raw = '9/11/2026 - 9/16/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-02-12'::date, 2, 86998.00, 'Opening sale (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - C' and travel_raw = '10/11/2026 - 10/16/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-02-12'::date, 15, 562485.00, 'Opening sale (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - D' and travel_raw = '11/15/2026 - 11/20/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-02-12'::date, 6, 224994.00, 'Opening sale (imported from file)' from public.collectives where package = '6D4N Korea Nami Island' and tour_code = 'JTKR1B1  - E' and travel_raw = '12/12/2026 - 12/17/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-07-07'::date, 25, 614675.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - A' and travel_raw = '2/28/2026 - 3/3/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-07-07'::date, 25, 624063.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - B' and travel_raw = '3/28/2026 - 3/31/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-07-07'::date, 25, 592082.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV12B2 - C' and travel_raw = '4/25/2026 - 4/28/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-10-23'::date, 25, 655972.00, 'Opening sale (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - A' and travel_raw = '1/14/2026 - 1/17/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-10-23'::date, 25, 647678.00, 'Opening sale (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - B' and travel_raw = '3/4/2026 - 3/7/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-10-23'::date, 15, 411585.00, 'Opening sale (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - C' and travel_raw = '4/22/2026 - 4/25/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-10-23'::date, 25, 645205.00, 'Opening sale (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - D' and travel_raw = '5/27/2026 - 5/30/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2025-10-23'::date, 25, 701185.08, 'Opening sale (imported from file)' from public.collectives where package = '5D3N Da Nang Charter (VJ VietJet)' and tour_code = 'UOV24B2 - E' and travel_raw = '6/10/2026 - 6/13/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 15, 325485.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - A' and travel_raw = '7/18/2026 - 7/21/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 15, 325485.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - B' and travel_raw = '8/15/2026 - 8/18/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 13, 282087.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - C' and travel_raw = '9/19/2026 - 9/22/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 15, 325485.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - D' and travel_raw = '10/24/2026 - 10/27/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 14, 304686.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - E' and travel_raw = '11/21/2026 - 11/24/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-01-26'::date, 14, 303786.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Da Nang Charter (5J Cebu Pacific)' and tour_code = 'UOV15B2 - F' and travel_raw = '12/12/2026 - 12/15/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 349484.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - A' and travel_raw = '7/3/2026 - 7/6/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 452169.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - B' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 341984.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - C' and travel_raw = '7/17/2026 - 7/20/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 383984.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - D' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 15, 345276.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - E' and travel_raw = '8/7/2026 - 8/10/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 354652.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Bangkok Blockings' and tour_code = 'SBBK1B2 - F' and travel_raw = '8/14/2026 - 8/17/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 358484.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - A' and travel_raw = '7/3/2026 - 7/6/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 518825.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - B' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 542993.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - C' and travel_raw = '7/17/2026 - 7/20/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 6, 146994.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - D' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 9, 198491.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - E' and travel_raw = '8/7/2026 - 8/10/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 15, 333485.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Hong Kong Blockings' and tour_code = 'CNHK1B1 - F' and travel_raw = '8/14/2026 - 8/17/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 16, 451484.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Singapore Blockings' and tour_code = 'TVSG1B1 - A' and travel_raw = '7/10/2026 - 7/13/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-24'::date, 15, 480985.00, 'Opening sale (imported from file)' from public.collectives where package = '4D3N Singapore Blockings' and tour_code = 'TVSG1B1 - B' and travel_raw = '7/24/2026 - 7/27/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-06'::date, 28, 1287972.00, 'Opening sale (imported from file)' from public.collectives where package = 'ADORA CRUISE MNL - JAPAN' and tour_code = 'UOAC2B2' and travel_raw = '12/21/2026 - 12/27/2026';
insert into public.collective_sales (collective_id, sold_on, slots, amount, note) select id, '2026-03-06'::date, 16, 735984.00, 'Opening sale (imported from file)' from public.collectives where package = 'ADORA CRUISE MNL - JAPAN' and tour_code = 'UOAC2B2' and travel_raw = '12/27/2026 - 01/02/2027';

commit;

-- ------------------------------------------------------ 5. VERIFY (run after)
-- Expect exactly: 42 | 18,652,163.36 | 10,511,401.36 | 8,140,762.00
--                    | 16,074,363.08 | 5,562,961.72  | 803 | 577 | 226
select count(*) as departures,
       to_char(sum(total_cost),      'FM999,999,999.00') as total_cost,
       to_char(sum(current_payment), 'FM999,999,999.00') as paid,
       to_char(sum(balance_payable), 'FM999,999,999.00') as balance_payable,
       to_char(sum(collected),       'FM999,999,999.00') as collected,
       to_char(sum(profit),          'FM999,999,999.00') as profit,
       sum(total_slots) as slots, sum(slot_sold) as sold, sum(remaining_slot) as remaining
from public.collective_summary;

-- Status split (should be 14 FINISHED / 28 PENDING as of 15 Jul 2026):
select status, count(*) from public.collective_summary group by status order by status;

-- ---------------------------------------------------------- 6. MAKE YOURSELF ADMIN
-- FIRST create your login: Authentication -> Users -> Add user. Then run:
-- insert into public.profiles (id, full_name, role)
-- select id, 'Administrator', 'admin' from auth.users where email = 'you@example.com'
-- on conflict (id) do update set role = 'admin';
--
-- Add a staff member the same way with role = 'regular'.