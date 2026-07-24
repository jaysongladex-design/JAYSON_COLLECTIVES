-- =============================================================================
--  collectives_public — readable, one-row-per-departure table (run ONCE)
--  New Supabase project → SQL Editor → paste → Run.
--
--  The app keeps its master copy in app_state (one JSON doc). On every save,
--  api/state.js ALSO writes each departure as a row here so you can browse them
--  in the Table Editor. This table is rebuilt from the app on each sync.
--
--  Private: RLS on, anon/authenticated get NOTHING (it holds cost/profit). Only
--  the service key (the Vercel function) and you (dashboard) can see it.
-- =============================================================================

create table if not exists public.collectives_public (
  id               text primary key,
  package          text,
  tour_code        text,
  travel_raw       text,
  travel_start     date,
  travel_end       date,
  status           text,          -- PENDING / FINISHED / VOID
  total_slots      integer,
  slots_sold       integer,
  slots_left       integer,
  price_per_pax    numeric,
  total_cost       numeric,
  current_payment  numeric,
  balance_payable  numeric,
  collected        numeric,
  profit           numeric,
  voided           boolean,
  updated_at       timestamptz default now()
);

alter table public.collectives_public enable row level security;   -- lock it down
revoke all on public.collectives_public from anon, authenticated;  -- public gets nothing
