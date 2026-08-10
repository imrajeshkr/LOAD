-- =============================================================================
-- LOAD — v2 schema proposal (greenfield design, NOT wired into migrations)
--
-- Design thesis: the current schema stores what happened but not what was
-- prescribed, and it stores exercises as free text. That makes the coach
-- unable to reason. This design separates four layers:
--
--   CATALOG      what exercises exist in the world      (global, shared)
--   PRESCRIPTION what this user is supposed to do       (per user, versioned)
--   PERFORMANCE  what this user actually did            (per user, append-only)
--   SIGNAL       body metrics, nutrition, coach dialog  (per user)
--
-- Everything measurable is stored canonically: kilograms, metres, seconds,
-- grams. Display conversion happens at the app boundary only.
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- =============================================================================
-- 0. ENUMS AND HELPERS
-- =============================================================================

create type unit_system        as enum ('metric', 'imperial');
create type training_goal      as enum ('build_muscle', 'lose_fat', 'recomposition', 'general_health', 'strength');
create type experience_level   as enum ('beginner', 'intermediate', 'advanced');
create type train_environment  as enum ('commercial_gym', 'home_gym', 'bodyweight_only');
create type split_type         as enum ('push_pull_legs', 'upper_lower', 'full_body', 'no_preference');
create type load_type          as enum ('weight_reps', 'bodyweight_reps', 'weighted_bodyweight',
                                        'assisted_bodyweight', 'time', 'distance');
create type muscle_role        as enum ('primary', 'secondary', 'stabiliser');
create type program_status     as enum ('draft', 'active', 'paused', 'completed', 'archived');
create type block_intent       as enum ('accumulation', 'intensification', 'peak', 'deload');
create type schedule_status    as enum ('pending', 'completed', 'skipped', 'missed');
create type session_status     as enum ('in_progress', 'completed', 'abandoned');
create type set_type           as enum ('warmup', 'working', 'backoff', 'drop', 'amrap', 'failure');
create type alt_reason         as enum ('joint_friendly', 'equipment_substitute', 'progression',
                                        'regression', 'variation');
create type coach_role         as enum ('user', 'assistant', 'system', 'tool');
create type proposal_kind      as enum ('log_sets', 'swap_exercise', 'adjust_program',
                                        'set_goal', 'log_bodyweight', 'log_nutrition');
create type proposal_status    as enum ('pending', 'confirmed', 'rejected', 'expired');
create type severity_level     as enum ('mild', 'moderate', 'severe');
create type authored_by        as enum ('coach_ai', 'user', 'template');

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- Epley estimate. IMMUTABLE so it can back a generated column.
create or replace function est_1rm(weight_kg numeric, reps int)
returns numeric language sql immutable as $$
  select case
    when weight_kg is null or reps is null or reps < 1 then null
    when reps = 1 then weight_kg
    else round(weight_kg * (1 + reps / 30.0), 2)
  end
$$;


-- =============================================================================
-- 1. IDENTITY AND PREFERENCES
--
-- Split from the old monolithic `profiles`: identity, display preferences and
-- training intent change at different rates and for different reasons.
-- =============================================================================

create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url   text,
  -- Every "day" boundary in the app (streaks, daily protein, the heatmap) is
  -- resolved in this zone. Without it, day-grouping is wrong for any user who
  -- travels or trains near midnight.
  timezone     text not null default 'UTC',
  locale       text not null default 'en',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table user_preferences (
  user_id              uuid primary key references profiles(id) on delete cascade,
  units                unit_system not null default 'metric',
  -- Smallest plate jump available to them; drives weight stepper increments
  -- and progression suggestions.
  weight_increment_kg  numeric(5,2) not null default 2.5,
  rest_timer_seconds   int not null default 120,
  notify_workout       boolean not null default true,
  notify_nutrition     boolean not null default true,
  updated_at           timestamptz not null default now()
);

-- Training intent is SLOWLY CHANGING (Type 2). Keeping history is what lets
-- the coach say "your bench stalled because you were in a deficit then".
-- The current row is the one with valid_to IS NULL.
create table training_profiles (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references profiles(id) on delete cascade,
  goal              training_goal not null,
  experience        experience_level not null,
  environment       train_environment not null,
  split_preference  split_type not null default 'no_preference',
  days_per_week     int not null default 4 check (days_per_week between 1 and 7),
  target_weight_kg  numeric(5,2) check (target_weight_kg > 0),
  target_date       date,
  valid_from        timestamptz not null default now(),
  valid_to          timestamptz,
  check (valid_to is null or valid_to > valid_from)
);

-- Exactly one current training profile per user.
create unique index training_profiles_current_uq
  on training_profiles (user_id) where valid_to is null;


-- =============================================================================
-- 2. CATALOG  (global reference data, shared across all users)
--
-- Replaces: hardcoded `defaultExercises`, `formCues` and `joints` lists in
-- lib/models/models.dart, and the free-text `session_sets.exercise_name`.
-- =============================================================================

create table muscles (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  muscle_group text not null            -- chest, back, legs, shoulders, arms, core
);

create table joints (
  id   uuid primary key default gen_random_uuid(),
  slug text not null unique,            -- shoulder, elbow, wrist, knee, hip, lumbar
  name text not null
);

create table equipment (
  id   uuid primary key default gen_random_uuid(),
  slug text not null unique,            -- barbell, dumbbell, cable, machine, bench, rack
  name text not null
);

-- Which equipment a given environment can be assumed to have. Lets plan
-- generation filter the catalog instead of hardcoding per-environment lists.
create table environment_equipment (
  environment  train_environment not null,
  equipment_id uuid not null references equipment(id) on delete cascade,
  primary key (environment, equipment_id)
);

create table exercises (
  id            uuid primary key default gen_random_uuid(),
  -- NULL = global catalog row. Non-null = a custom exercise this user created.
  owner_id      uuid references profiles(id) on delete cascade,
  slug          text not null,
  name          text not null,
  load_type     load_type not null default 'weight_reps',
  is_unilateral boolean not null default false,
  -- Sensible prescription defaults used when generating a plan.
  default_rep_low   int check (default_rep_low  > 0),
  default_rep_high  int check (default_rep_high >= default_rep_low),
  description   text,
  video_url     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Global slugs are globally unique; per-user custom slugs are unique per user.
create unique index exercises_global_slug_uq on exercises (slug) where owner_id is null;
create unique index exercises_owner_slug_uq  on exercises (owner_id, slug) where owner_id is not null;

-- Per-muscle contribution is what makes "sets per muscle per week" — the
-- metric hypertrophy training actually runs on — a SQL query instead of guesswork.
create table exercise_muscles (
  exercise_id  uuid not null references exercises(id) on delete cascade,
  muscle_id    uuid not null references muscles(id)   on delete cascade,
  role         muscle_role not null default 'primary',
  contribution numeric(3,2) not null default 1.0 check (contribution between 0 and 1),
  primary key (exercise_id, muscle_id)
);

-- Drives the "Watch your shoulder" warning by joining against user_constraints,
-- instead of substring-matching a free-text injuries field.
create table exercise_joints (
  exercise_id  uuid not null references exercises(id) on delete cascade,
  joint_id     uuid not null references joints(id)    on delete cascade,
  stress_level severity_level not null default 'moderate',
  primary key (exercise_id, joint_id)
);

create table exercise_equipment (
  exercise_id  uuid not null references exercises(id) on delete cascade,
  equipment_id uuid not null references equipment(id) on delete cascade,
  is_required  boolean not null default true,
  primary key (exercise_id, equipment_id)
);

-- Replaces the `formCues` map.
create table exercise_cues (
  id          uuid primary key default gen_random_uuid(),
  exercise_id uuid not null references exercises(id) on delete cascade,
  position    int  not null,
  body        text not null,
  unique (exercise_id, position)
);

-- Backs the "Swap" button. Directed and typed, so the coach can pick the
-- right substitute for the right reason.
create table exercise_alternatives (
  exercise_id     uuid not null references exercises(id) on delete cascade,
  alternative_id  uuid not null references exercises(id) on delete cascade,
  reason          alt_reason not null,
  rank            int not null default 1,
  primary key (exercise_id, alternative_id, reason),
  check (exercise_id <> alternative_id)
);


-- =============================================================================
-- 3. USER CONSTRAINTS  (replaces `profiles.injuries text`)
--
-- Structured, joint-referencing and time-bounded. A shoulder that hurt in
-- March should stop suppressing overhead work in September.
-- =============================================================================

create table user_constraints (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  joint_id   uuid references joints(id) on delete restrict,
  label      text not null,                    -- "Cranky left shoulder"
  severity   severity_level not null default 'moderate',
  side       text check (side in ('left','right','bilateral')),
  note       text,
  active_from date not null default current_date,
  active_to   date,
  check (active_to is null or active_to >= active_from)
);

create index user_constraints_active_idx
  on user_constraints (user_id, joint_id) where active_to is null;


-- =============================================================================
-- 4. PRESCRIPTION  (programs → blocks → days → exercises)
--
-- Entirely absent today: "Push Day" and its four exercises are a Dart const.
-- =============================================================================

create table programs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  name          text not null,
  goal          training_goal not null,
  split         split_type not null,
  days_per_week int not null check (days_per_week between 1 and 7),
  status        program_status not null default 'draft',
  authored_by   authored_by not null default 'coach_ai',
  starts_on     date,
  ends_on       date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (id, user_id),                        -- target for composite FKs below
  check (ends_on is null or starts_on is null or ends_on >= starts_on)
);

-- At most one active program per user — an invariant the app currently has to
-- trust itself to maintain.
create unique index programs_one_active_uq
  on programs (user_id) where status = 'active';

-- Mesocycles. Optional, but this is where periodisation and deloads live.
create table program_blocks (
  id          uuid primary key default gen_random_uuid(),
  program_id  uuid not null references programs(id) on delete cascade,
  ordinal     int  not null,
  name        text not null,
  intent      block_intent not null default 'accumulation',
  week_count  int  not null default 4 check (week_count > 0),
  unique (program_id, ordinal)
);

-- One rotation slot: "Push Day" is a row here, not a string on a session.
create table program_days (
  id         uuid primary key default gen_random_uuid(),
  program_id uuid not null references programs(id) on delete cascade,
  block_id   uuid references program_blocks(id) on delete cascade,
  ordinal    int  not null,                    -- position in the rotation
  label      text not null,                    -- "Push Day"
  notes      text,
  unique (program_id, ordinal),
  unique (id, program_id)
);

-- The prescription itself: sets, rep range, target load. This is what the
-- "0/4 sets" counter on the Today screen should read from.
create table program_day_exercises (
  id              uuid primary key default gen_random_uuid(),
  program_day_id  uuid not null references program_days(id) on delete cascade,
  exercise_id     uuid not null references exercises(id) on delete restrict,
  ordinal         int  not null,
  sets_target     int  not null check (sets_target > 0),
  rep_low         int  not null check (rep_low > 0),
  rep_high        int  not null check (rep_high >= rep_low),
  target_weight_kg numeric(6,2) check (target_weight_kg >= 0),
  target_rpe      numeric(3,1) check (target_rpe between 1 and 10),
  rest_seconds    int not null default 120,
  -- Same value = performed as a superset.
  superset_group  smallint,
  notes           text,
  unique (program_day_id, ordinal)
);


-- =============================================================================
-- 5. SCHEDULING  (the calendar — planned vs actual adherence)
-- =============================================================================

create table scheduled_workouts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references profiles(id) on delete cascade,
  program_id      uuid not null,
  program_day_id  uuid not null,
  scheduled_for   date not null,
  status          schedule_status not null default 'pending',
  created_at      timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, scheduled_for, program_day_id),
  foreign key (program_id, user_id)      references programs(id, user_id) on delete cascade,
  foreign key (program_day_id, program_id) references program_days(id, program_id) on delete cascade
);

create index scheduled_workouts_upcoming_idx
  on scheduled_workouts (user_id, scheduled_for) where status = 'pending';


-- =============================================================================
-- 6. PERFORMANCE  (session → session_exercise → set)
--
-- The missing middle layer is `session_exercises`. Without it there is nowhere
-- to record "you swapped Bench for Floor Press", nowhere to hang per-exercise
-- ordering, and set→exercise identity is a text string.
-- =============================================================================

create table workout_sessions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references profiles(id) on delete cascade,
  -- Both nullable: unplanned, off-program sessions are legitimate.
  scheduled_workout_id uuid,
  program_day_id       uuid references program_days(id) on delete set null,
  title                text not null,
  -- The user-local calendar day. Derived once, on completion, from the user's
  -- timezone — never re-derived client-side. Every streak/heatmap/daily
  -- aggregate groups on this, not on completed_at.
  performed_on         date not null default current_date,
  started_at           timestamptz not null default now(),
  completed_at         timestamptz,
  status               session_status not null default 'in_progress',
  session_rpe          numeric(3,1) check (session_rpe between 1 and 10),
  bodyweight_kg        numeric(5,2),           -- snapshot, for bodyweight-load maths
  notes                text not null default '',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (id, user_id),
  foreign key (scheduled_workout_id, user_id)
    references scheduled_workouts(id, user_id) on delete set null,
  check ((status = 'completed') = (completed_at is not null))
);

-- One in-progress session at a time.
create unique index workout_sessions_one_open_uq
  on workout_sessions (user_id) where status = 'in_progress';

create table session_exercises (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null,
  session_id              uuid not null,
  exercise_id             uuid not null references exercises(id) on delete restrict,
  -- Links performance back to prescription. Null for ad-hoc additions.
  program_day_exercise_id uuid references program_day_exercises(id) on delete set null,
  -- Non-null records that this slot was substituted, and from what.
  swapped_from_exercise_id uuid references exercises(id) on delete set null,
  swap_reason             alt_reason,
  ordinal                 int not null,
  notes                   text,
  unique (id, user_id),
  unique (session_id, ordinal),
  -- Composite FK: guarantees the denormalised user_id can never drift from
  -- the parent session's. Denormalisation is deliberate — it keeps RLS
  -- predicates single-table and index-only.
  foreign key (session_id, user_id) references workout_sessions(id, user_id) on delete cascade
);

create table session_sets (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  session_exercise_id uuid not null,
  set_number          int  not null check (set_number > 0),
  kind                set_type not null default 'working',

  -- Nullable by load_type: a plank has duration but no reps, a run has
  -- distance, a pull-up has reps but no external weight.
  weight_kg           numeric(6,2) check (weight_kg >= 0),
  reps                int          check (reps >= 0),
  duration_seconds    int          check (duration_seconds > 0),
  distance_m          numeric(8,2) check (distance_m > 0),

  rpe                 numeric(3,1) check (rpe between 1 and 10),
  rir                 int          check (rir between 0 and 10),
  is_completed        boolean not null default true,
  performed_at        timestamptz not null default now(),

  -- Stored generated columns: tonnage and e1RM become indexable facts rather
  -- than something every client recomputes over raw rows.
  volume_kg numeric generated always as
    (coalesce(weight_kg, 0) * coalesce(reps, 0)) stored,
  e1rm_kg   numeric generated always as
    (est_1rm(weight_kg, reps)) stored,

  unique (session_exercise_id, set_number),
  foreign key (session_exercise_id, user_id)
    references session_exercises(id, user_id) on delete cascade,
  -- A set must quantify something.
  check (reps is not null or duration_seconds is not null or distance_m is not null)
);

-- Replaces `sessions.pain text[]` — typed, joint-referencing, gradeable.
create table session_pain_reports (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,
  session_id uuid not null,
  joint_id   uuid not null references joints(id) on delete restrict,
  severity   severity_level not null,
  note       text,
  foreign key (session_id, user_id) references workout_sessions(id, user_id) on delete cascade
);

create index session_pain_reports_session_idx on session_pain_reports (session_id);


-- =============================================================================
-- 7. SIGNAL  (body metrics and nutrition)
--
-- Bodyweight is one-per-day and upserted. Nutrition is append-only entries
-- (you eat several times a day) with a daily rollup view over the top —
-- the current single `protein_logs` table conflates the two shapes.
-- =============================================================================

create table body_measurements (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  measured_on   date not null default current_date,
  weight_kg     numeric(5,2) check (weight_kg > 0),
  body_fat_pct  numeric(4,1) check (body_fat_pct between 1 and 70),
  waist_cm      numeric(5,1),
  chest_cm      numeric(5,1),
  arm_cm        numeric(5,1),
  thigh_cm      numeric(5,1),
  source        text not null default 'manual',   -- manual | healthkit | scale_api
  created_at    timestamptz not null default now(),
  unique (user_id, measured_on)                   -- one row per day, upserted
);

create table nutrition_entries (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  logged_on  date not null default current_date,
  logged_at  timestamptz not null default now(),
  label      text,
  protein_g  numeric(6,1) not null default 0 check (protein_g >= 0),
  calories   numeric(7,1) check (calories >= 0),
  carbs_g    numeric(6,1) check (carbs_g >= 0),
  fat_g      numeric(6,1) check (fat_g >= 0)
);

create index nutrition_entries_day_idx on nutrition_entries (user_id, logged_on);

-- Targets are versioned so a change of goal doesn't rewrite history.
create table nutrition_targets (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  protein_g      int not null check (protein_g > 0),
  calories       int check (calories > 0),
  valid_from     date not null default current_date,
  valid_to       date,
  check (valid_to is null or valid_to > valid_from)
);

create unique index nutrition_targets_current_uq
  on nutrition_targets (user_id) where valid_to is null;


-- =============================================================================
-- 8. COACH
--
-- Adds a thread, a proper role enum, and — the important one — durable
-- proposals. The "Confirm session log" card currently exists only in memory,
-- so killing the app loses it and there is no record of what the model
-- suggested versus what the user accepted.
-- =============================================================================

create table coach_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references profiles(id) on delete cascade,
  title           text,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (id, user_id)
);

create table coach_messages (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  thread_id    uuid not null,
  role         coach_role not null,
  content      text not null,
  -- Provenance for evaluating and costing the coach over time.
  model        text,
  input_tokens  int,
  output_tokens int,
  created_at   timestamptz not null default now(),
  unique (id, user_id),
  foreign key (thread_id, user_id) references coach_threads(id, user_id) on delete cascade
);

create index coach_messages_thread_idx on coach_messages (thread_id, created_at);

create table coach_proposals (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  message_id   uuid not null,
  kind         proposal_kind not null,
  -- Parsed intent, e.g. {"sets":[{"exercise_id":"…","weight_kg":80,"reps":8,"count":4}]}
  payload      jsonb not null,
  status       proposal_status not null default 'pending',
  resolved_at  timestamptz,
  -- What the confirmation actually produced, for auditability.
  result_session_id uuid references workout_sessions(id) on delete set null,
  created_at   timestamptz not null default now(),
  foreign key (message_id, user_id) references coach_messages(id, user_id) on delete cascade,
  check ((status = 'pending') = (resolved_at is null))
);

create index coach_proposals_pending_idx
  on coach_proposals (user_id) where status = 'pending';


-- =============================================================================
-- 9. DERIVED VIEWS
--
-- Aggregation moves to the database. Today the client pulls up to 600 raw set
-- rows to compute an exercise-frequency list, and recomputes tonnage on every
-- render of the history screen.
-- =============================================================================

-- Per-session rollup: set count and tonnage.
create view v_session_totals with (security_invoker = true) as
select
  ws.id            as session_id,
  ws.user_id,
  ws.title,
  ws.performed_on,
  ws.completed_at,
  count(ss.id)                as set_count,
  coalesce(sum(ss.volume_kg), 0) as volume_kg,
  count(distinct se.exercise_id) as exercise_count
from workout_sessions ws
left join session_exercises se on se.session_id = ws.id
left join session_sets     ss on ss.session_exercise_id = se.id and ss.is_completed
where ws.status = 'completed'
group by ws.id;

-- Strength trend: heaviest working set and best e1RM per exercise per day.
create view v_exercise_daily_bests with (security_invoker = true) as
select
  se.user_id,
  se.exercise_id,
  ws.performed_on,
  max(ss.weight_kg) as top_weight_kg,
  max(ss.e1rm_kg)   as best_e1rm_kg,
  count(*)          as set_count
from session_sets ss
join session_exercises se on se.id = ss.session_exercise_id
join workout_sessions  ws on ws.id = se.session_id
where ss.is_completed and ss.kind in ('working', 'amrap', 'failure')
group by se.user_id, se.exercise_id, ws.performed_on;

-- Weekly hard sets per muscle — the primary hypertrophy dose metric, and
-- impossible to compute at all under the current free-text schema.
create view v_weekly_muscle_volume with (security_invoker = true) as
select
  se.user_id,
  em.muscle_id,
  date_trunc('week', ws.performed_on)::date as week_start,
  sum(em.contribution)              as effective_sets,
  sum(ss.volume_kg * em.contribution) as effective_volume_kg
from session_sets ss
join session_exercises se on se.id = ss.session_exercise_id
join workout_sessions  ws on ws.id = se.session_id
join exercise_muscles  em on em.exercise_id = se.exercise_id
where ss.is_completed and ss.kind in ('working', 'amrap', 'failure')
group by se.user_id, em.muscle_id, 3;

-- Daily nutrition rollup against the target in force that day.
create view v_nutrition_daily with (security_invoker = true) as
select
  ne.user_id,
  ne.logged_on,
  sum(ne.protein_g) as protein_g,
  sum(ne.calories)  as calories,
  (select nt.protein_g from nutrition_targets nt
    where nt.user_id = ne.user_id
      and nt.valid_from <= ne.logged_on
      and (nt.valid_to is null or nt.valid_to > ne.logged_on)
    limit 1) as protein_target_g
from nutrition_entries ne
group by ne.user_id, ne.logged_on;

-- Adherence: what was scheduled versus what was performed.
create view v_adherence with (security_invoker = true) as
select
  sw.user_id,
  sw.scheduled_for,
  sw.status as scheduled_status,
  ws.id     as session_id,
  ws.status as session_status
from scheduled_workouts sw
left join workout_sessions ws on ws.scheduled_workout_id = sw.id;

-- Exercises that stress a joint the user has flagged. This single view
-- replaces the app's substring matching on a free-text injuries field.
create view v_flagged_exercises with (security_invoker = true) as
select distinct
  uc.user_id,
  ej.exercise_id,
  j.slug as joint_slug,
  ej.stress_level,
  uc.label as constraint_label
from user_constraints uc
join joints          j  on j.id = uc.joint_id
join exercise_joints ej on ej.joint_id = uc.joint_id
where uc.active_to is null;


-- =============================================================================
-- 10. INDEXES  (beyond the PK/unique indexes declared inline)
-- =============================================================================

create index workout_sessions_user_day_idx
  on workout_sessions (user_id, performed_on desc) where status = 'completed';

create index session_exercises_session_idx on session_exercises (session_id, ordinal);
create index session_exercises_user_ex_idx on session_exercises (user_id, exercise_id);
create index session_sets_parent_idx       on session_sets (session_exercise_id, set_number);
create index session_sets_user_time_idx    on session_sets (user_id, performed_at desc);
create index body_measurements_user_idx    on body_measurements (user_id, measured_on desc);
create index program_day_exercises_day_idx on program_day_exercises (program_day_id, ordinal);
create index exercise_muscles_muscle_idx   on exercise_muscles (muscle_id);
create index exercise_joints_joint_idx     on exercise_joints (joint_id);


-- =============================================================================
-- 11. TRIGGERS
-- =============================================================================

create trigger profiles_updated          before update on profiles          for each row execute function set_updated_at();
create trigger user_preferences_updated   before update on user_preferences  for each row execute function set_updated_at();
create trigger exercises_updated          before update on exercises         for each row execute function set_updated_at();
create trigger programs_updated           before update on programs          for each row execute function set_updated_at();
create trigger workout_sessions_updated   before update on workout_sessions  for each row execute function set_updated_at();

-- Stamp performed_on in the user's own timezone at completion time.
create or replace function stamp_performed_on() returns trigger
language plpgsql as $$
declare tz text;
begin
  if new.completed_at is not null then
    select timezone into tz from profiles where id = new.user_id;
    new.performed_on := (new.completed_at at time zone coalesce(tz, 'UTC'))::date;
  end if;
  return new;
end $$;

create trigger workout_sessions_performed_on
  before insert or update of completed_at on workout_sessions
  for each row execute function stamp_performed_on();

-- Provision the dependent rows a new user needs.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id) values (new.id);
  insert into user_preferences (user_id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();


-- =============================================================================
-- 12. ROW LEVEL SECURITY
--
-- Two shapes:
--   catalog tables  — readable by any authenticated user, writable only by
--                     the service role (no policy = no access under RLS).
--   user tables     — full access to owner only, via a single-table predicate
--                     on the denormalised user_id (no joins in the predicate).
-- =============================================================================

-- ---- catalog: read-only to users ----
do $$
declare t text;
begin
  foreach t in array array[
    'muscles','joints','equipment','environment_equipment',
    'exercise_muscles','exercise_joints','exercise_equipment',
    'exercise_cues','exercise_alternatives'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for select to authenticated using (true)',
      t || '_read', t);
  end loop;
end $$;

-- exercises: global rows plus your own customs; you may only write your own.
alter table exercises enable row level security;
create policy exercises_read on exercises for select to authenticated
  using (owner_id is null or owner_id = (select auth.uid()));
create policy exercises_write_own on exercises for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- ---- user-owned tables ----
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_preferences','training_profiles','user_constraints',
    'programs','scheduled_workouts','workout_sessions','session_exercises',
    'session_sets','session_pain_reports','body_measurements',
    'nutrition_entries','nutrition_targets','coach_threads','coach_messages',
    'coach_proposals'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for all to authenticated using (%s = (select auth.uid())) with check (%s = (select auth.uid()))',
      t || '_own', t,
      case when t = 'profiles' then 'id' else 'user_id' end,
      case when t = 'profiles' then 'id' else 'user_id' end);
  end loop;
end $$;

-- Program children have no user_id of their own; they inherit via the parent.
-- Kept as an EXISTS predicate because these tables are small and rarely hot.
alter table program_blocks        enable row level security;
alter table program_days          enable row level security;
alter table program_day_exercises enable row level security;

create policy program_blocks_own on program_blocks for all to authenticated
  using (exists (select 1 from programs p
                  where p.id = program_id and p.user_id = (select auth.uid())));

create policy program_days_own on program_days for all to authenticated
  using (exists (select 1 from programs p
                  where p.id = program_id and p.user_id = (select auth.uid())));

create policy program_day_exercises_own on program_day_exercises for all to authenticated
  using (exists (select 1 from program_days d
                  join programs p on p.id = d.program_id
                  where d.id = program_day_id and p.user_id = (select auth.uid())));
