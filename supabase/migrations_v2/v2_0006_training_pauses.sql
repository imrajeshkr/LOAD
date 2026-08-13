-- =============================================================================
-- LOAD v2 — paused training
--
-- The Profile tab models pause as a single boolean. That is not enough.
--
-- The promise attached to the feature is "the weeks off will not count against
-- your consistency" — and consistency is computed over date ranges. A boolean
-- can say the user is paused *right now*; it cannot say which past weeks to
-- exclude from the Progress tab's sessions-per-week rate, which is the entire
-- point of the promise. So: dated ranges.
--
-- Three downstream effects, all keyed off these rows:
--   * nudges suppressed while a pause is open
--   * progression holds — no auto-increase while paused
--   * paused weeks excluded from the consistency denominator
-- =============================================================================

do $$ begin
  create type pause_reason as enum ('illness', 'travel', 'injury', 'other');
exception when duplicate_object then null;
end $$;

create table if not exists training_pauses (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  started_on date not null default current_date,
  -- NULL = still paused. Resuming stamps this.
  ended_on   date,
  reason     pause_reason not null default 'other',
  note       text,
  created_at timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on)
);

-- At most one open pause. Resuming and re-pausing creates a second row, which
-- is what we want — two separate weeks off are two separate exclusions.
create unique index if not exists training_pauses_one_open_uq
  on training_pauses (user_id) where ended_on is null;

create index if not exists training_pauses_range_idx
  on training_pauses (user_id, started_on, ended_on);

alter table training_pauses enable row level security;

create policy training_pauses_own on training_pauses
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));


-- ── is the user paused right now ────────────────────────────────────────
create or replace function is_training_paused(p_user_id uuid)
returns boolean
language sql stable security invoker as $$
  select exists (
    select 1 from training_pauses
     where user_id = p_user_id
       and ended_on is null
       and started_on <= user_today(p_user_id)
  );
$$;

grant execute on function is_training_paused(uuid) to authenticated;


-- ── how many days in a window were paused ───────────────────────────────
-- Consistency maths subtracts these. Overlapping pauses cannot happen (one
-- open at a time) but a closed and an open pause can both touch the window,
-- so the ranges are unioned rather than summed.
create or replace function paused_days_between(p_user_id uuid, p_from date, p_to date)
returns int
language sql stable security invoker as $$
  with clipped as (
    select greatest(started_on, p_from) as s,
           least(coalesce(ended_on, p_to), p_to) as e
      from training_pauses
     where user_id = p_user_id
       and started_on <= p_to
       and coalesce(ended_on, p_to) >= p_from
  ),
  days as (
    select distinct generate_series(s, e, interval '1 day')::date as d
      from clipped where e >= s
  )
  select coalesce(count(*), 0)::int from days;
$$;

grant execute on function paused_days_between(uuid, date, date) to authenticated;

comment on function paused_days_between(uuid, date, date) is
  'Distinct paused days in [p_from, p_to]. The Progress consistency rate divides '
  'sessions by (elapsed weeks - paused weeks) so time off does not read as failure.';
