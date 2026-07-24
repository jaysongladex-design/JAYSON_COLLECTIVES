-- =============================================================================
--  Collectives — app data storage (run ONCE in the new Supabase project)
--  Supabase → SQL Editor → New query → paste → Run.
--
--  One row of this table holds your WHOLE app (users + all departures + logs)
--  as a JSON document. The app loads it on startup and saves it on every change
--  through a Vercel function (api/state.js) that uses the SERVICE key.
--
--  Security: RLS is on and the anon/authenticated (public) keys get NOTHING —
--  only the service key (used server-side by the Vercel function) can read or
--  write it. So the data (including financials) is never exposed publicly.
-- =============================================================================

create table if not exists public.app_state (
  id          text primary key,          -- always the string 'main'
  data        jsonb not null,            -- the entire app DB as JSON
  updated_at  timestamptz not null default now()
);

alter table public.app_state enable row level security;   -- lock it down
revoke all on public.app_state from anon, authenticated;  -- public gets nothing
