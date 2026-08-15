-- =============================================================================
-- LOAD v2 — profile, equipment, and preferences
--
-- The v2 onboarding captures several things the v1 profile cannot hold:
--
--   * Goals are an ordered multi-select, not one enum. The first pick "leads"
--     and that order is meaningful, so it is stored as an array rather than a
--     join table — it is read whole, written whole, and never queried by
--     individual element.
--
--   * The bodyweight target is tri-state. A nullable target_weight_kg cannot
--     distinguish "not asked yet" from "user declined to set one", and the
--     design is explicit that declining is a legitimate answer rather than a
--     gap to nag about. Hence a separate direction column.
--
--   * Bar weight and plate inventory together decide which loads are physically
--     loadable. Without them the coach will happily prescribe 42.5 kg to
--     someone whose gym has no 1.25s.
--
--   * Which weekdays, not just how many. programs.days_per_week is a count;
--     the streak strip and the schedule need the actual days.
-- =============================================================================

-- ── goals: ordered multi-select ─────────────────────────────────────────
-- Kept alongside the existing single `goal` column rather than replacing it:
-- bootstrap_user_program still keys off `goal`, and per decision D6 the lead
-- goal drives generation for v1. `goal` is therefore maintained as a
-- denormalised copy of goals[1] by the trigger below.
alter table training_profiles
  add column if not exists goals training_goal[] not null default '{}';

-- "I don't know — you choose" is a real answer, distinct from an empty array
-- (which means "not asked yet"). Onboarding cannot advance past the goal step
-- without one or the other being set, so the two states never collide.
alter table training_profiles
  add column if not exists goal_is_coach_choice boolean not null default false;

comment on column training_profiles.goals is
  'Ordered; goals[1] is the lead goal and drives plan generation. Empty means '
  'not answered yet — see goal_is_coach_choice for the explicit "you pick" answer.';

-- Keep the legacy single-goal column in step with the lead goal so existing
-- plan generation keeps working untouched.
create or replace function sync_lead_goal() returns trigger
language plpgsql as $$
begin
  if array_length(new.goals, 1) >= 1 then
    new.goal := new.goals[1];
  end if;
  return new;
end $$;

drop trigger if exists training_profiles_lead_goal on training_profiles;
create trigger training_profiles_lead_goal
  before insert or update of goals on training_profiles
  for each row execute function sync_lead_goal();

-- Backfill: existing rows have a single goal and no array.
update training_profiles
   set goals = array[goal]
 where cardinality(goals) = 0 and goal is not null;


-- ── bodyweight target: tri-state ────────────────────────────────────────
do $$ begin
  create type weight_goal_direction as enum ('lose', 'maintain', 'gain', 'declined');
exception when duplicate_object then null;
end $$;

alter table training_profiles
  add column if not exists target_direction weight_goal_direction;

comment on column training_profiles.target_direction is
  'NULL = not answered yet. ''declined'' = user explicitly opted out of a target, '
  'which is a valid answer and must not be re-prompted. target_weight_kg is only '
  'meaningful for lose/gain.';

-- Infer a direction for existing rows that already have a target.
update training_profiles tp
   set target_direction = case
         when tp.target_weight_kg is null then null
         when tp.target_weight_kg < coalesce(
                (select bm.weight_kg from body_measurements bm
                  where bm.user_id = tp.user_id and bm.weight_kg is not null
                  order by bm.measured_on desc limit 1), tp.target_weight_kg)
           then 'lose'::weight_goal_direction
         when tp.target_weight_kg > coalesce(
                (select bm.weight_kg from body_measurements bm
                  where bm.user_id = tp.user_id and bm.weight_kg is not null
                  order by bm.measured_on desc limit 1), tp.target_weight_kg)
           then 'gain'::weight_goal_direction
         else 'maintain'::weight_goal_direction
       end
 where tp.target_direction is null and tp.target_weight_kg is not null;


-- ── which weekdays, not just how many ───────────────────────────────────
-- ISO weekday numbers (1 = Monday .. 7 = Sunday) to match extract(isodow).
alter table training_profiles
  add column if not exists training_weekdays smallint[] not null default '{}';

alter table training_profiles
  drop constraint if exists training_weekdays_valid;
alter table training_profiles
  add constraint training_weekdays_valid
  check (training_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]);

comment on column training_profiles.training_weekdays is
  'ISO weekdays (1=Mon..7=Sun) the user intends to train. Empty = not answered. '
  'days_per_week on programs stays the count; this is the placement.';


-- ── equipment: bar and plates ───────────────────────────────────────────
-- Both live on the training profile rather than a separate equipment table:
-- there is exactly one bar and one plate set per user, they are always read
-- together with the rest of the profile, and neither is queried independently.
alter table training_profiles
  add column if not exists bar_weight_kg numeric(4,1)
  check (bar_weight_kg is null or bar_weight_kg between 0 and 50);

-- Plate sizes the gym actually has, per side, in kg. Quantity is deliberately
-- not modelled — the design toggles sizes, not counts, and "do I own any 2.5s"
-- is the question that constrains loading.
alter table training_profiles
  add column if not exists plate_sizes_kg numeric(4,2)[] not null
  default '{20,10,5,2.5,1.25}';

comment on column training_profiles.plate_sizes_kg is
  'Available plate sizes per side, kg. Combined with bar_weight_kg this defines '
  'the set of loadable weights: bar + 2 * (any multiset of these).';

-- Never benched is a branch, not an experience level: an intermediate lifter
-- can still have never benched. It triggers the bar-only technique week.
alter table training_profiles
  add column if not exists has_benched boolean;

comment on column training_profiles.has_benched is
  'NULL = not asked. false routes onboarding to the empty-bar 5x5 technique '
  'start instead of asking for a working load.';


-- ── preferences ─────────────────────────────────────────────────────────
-- All of these apply instantly in the Profile tab (no staging), which is why
-- they sit here and not in the staged-plan concept.
do $$ begin
  create type effort_prompt_frequency as enum ('first_set', 'every_set', 'never');
exception when duplicate_object then null;
end $$;

alter table user_preferences
  add column if not exists default_rest_seconds int not null default 90
    check (default_rest_seconds between 15 and 600),
  add column if not exists effort_prompt effort_prompt_frequency not null default 'first_set',
  add column if not exists auto_start_rest boolean not null default true,
  add column if not exists keep_screen_awake boolean not null default true,
  add column if not exists rest_end_sound boolean not null default true,
  add column if not exists notify_morning_note boolean not null default true,
  add column if not exists notify_session_debrief boolean not null default true,
  add column if not exists notify_missed_session boolean not null default true,
  add column if not exists notify_weekly_review boolean not null default true;

comment on column user_preferences.effort_prompt is
  'How often the session flow asks "could you have done another rep?". '
  '''never'' leaves the Progress effort histogram empty by design — the UI says so.';
