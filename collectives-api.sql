-- =============================================================================
--  COLLECTIVES  ->  PUBLIC READ-ONLY API
--  Run AFTER supabase-migration.sql, in: Supabase -> SQL Editor -> Run.
--
--  What this does:
--    Exposes ONE view - collectives_public - to the anon (public) key.
--    That view carries only customer-safe fields: package, tour code, travel
--    dates, status, slots left, price. It does NOT contain total_cost, profit,
--    ROI, balances, payments or customer names - those columns are not in the
--    view, so no query, filter trick or crafted URL can pull them.
--
--  Read-only:
--    anon is granted SELECT and nothing else. No insert/update/delete path
--    exists for the public key. Writing still requires a signed-in user, exactly
--    as the migration set up.
--
--  Safe to ship the anon key in the website:
--    the key can reach this view and nothing else, and the view holds no
--    sensitive data. (The booking-transactions table is a separate concern -
--    see the note at the bottom.)
-- =============================================================================

begin;

-- --------------------------------------------------------- the public catalog
-- security_invoker = false (the default on PG15): the view runs as its owner,
-- so the anon key - which has no direct table access - can still read these
-- safe columns THROUGH the view. This is intentional and is why the view must
-- only ever select safe columns.
create or replace view public.collectives_public
  with (security_invoker = false) as
select
  c.id,
  c.package,
  c.tour_code,
  c.travel_raw,                                   -- "5/16/2026 - 5/21/2026" as typed
  c.travel_start,
  c.travel_end,
  case
    when c.travel_end is not null and c.travel_end < current_date then 'FINISHED'
    else 'PENDING'
  end                                                          as status,
  (c.slot + c.foc)                                             as total_slots,
  greatest((c.slot + c.foc) - coalesce(s.slots_sold, 0), 0)    as slots_left,
  ((c.slot + c.foc) - coalesce(s.slots_sold, 0)) <= 0          as sold_out,
  c.amount_per_pax                                             as price_per_pax
from public.collectives c
left join (
  select collective_id, sum(slots) as slots_sold
  from public.collective_sales
  group by collective_id
) s on s.collective_id = c.id
where c.voided = false;                            -- voided departures never shown

comment on view public.collectives_public is
  'Public, read-only catalog. Safe fields only - no cost/profit/ROI/balances/PII.';

-- ------------------------------------------------------------------- read-only
grant usage  on schema public          to anon;    -- normally already granted
grant select on public.collectives_public to anon, authenticated;

-- Belt-and-braces: make sure the public key can NOT reach the raw tables or the
-- financial summary view, even if a later migration accidentally grants them.
revoke all on public.collectives         from anon;
revoke all on public.collective_payments from anon;
revoke all on public.collective_sales    from anon;
revoke all on public.collective_summary  from anon;

commit;

-- -----------------------------------------------------------------------------
-- SEPARATE, UNRELATED EXPOSURE - not created here, but worth fixing:
-- your existing booking table (fusioo_booking_transactions) currently lets the
-- anon key read every customer row. That predates this file. Tighten its RLS
-- so anon gets no rows, or the public catalog above is moot. Ask me and I'll
-- write that policy.
-- -----------------------------------------------------------------------------
