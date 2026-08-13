-- =============================================================================
-- LOAD v2 — session provenance
--
-- Implements decisions D1, D2, D4 (docs/08 §4, decided 2026-08-13) plus two
-- fixes from the cross-validation (docs/09): the weight-step column (F4) and
-- the NOT NULL columns v2 onboarding no longer asks for.
--
-- The theme of this migration: record not just WHAT was logged but HOW it was
-- entered. A set the user typed between efforts and a set auto-accepted at its
-- planned default are different qualities of evidence, and progression logic
-- that can't tell them apart is progressing on guesses.
-- =============================================================================

-- ── D1: effort, asked once per lift ─────────────────────────────────────
-- The answer itself lives on session_exercises (it is a per-lift fact — asked
-- once, after set 1). The CLIENT additionally writes the mapped RIR onto the
-- sets the answer covers (easy→3, right→1, all→0) so that the Progress
-- histogram and stall detection read one column (session_sets.rir) and a
-- future per-set mode needs no migration.
do $$ begin
  create type effort_answer as enum ('easy', 'right', 'all');
exception when duplicate_object then null;
end $$;

comment on type effort_answer is
  '"Could you have done another rep?" — easy = yes three or more, right = maybe '
  'one or two, all = no, that was everything. RIR mapping: 3 / 1 / 0.';

alter table session_exercises
  add column if not exists effort effort_answer;

-- ── entry provenance per lift ───────────────────────────────────────────
do $$ begin
  create type set_entry_mode as enum ('live', 'bulk', 'deferred');
exception when duplicate_object then null;
end $$;

alter table session_exercises
  add column if not exists entry_mode set_entry_mode,
  add column if not exists is_unconfirmed boolean not null default false;

comment on column session_exercises.entry_mode is
  'live = set-by-set during the session; bulk = "done all sets" batch entry; '
  'deferred = "log at the end". NULL for pre-v2 history.';

comment on column session_exercises.is_unconfirmed is
  'True when a deferred lift was auto-saved at its planned numbers without the '
  'user touching them. These sets are accepted guesses, not measurements — '
  'progression treats them as weaker evidence and the trainer can say so.';

-- ── session-level situation ─────────────────────────────────────────────
-- "Today feels off?" — changes prescribed sets (time → cap at 2) and loads
-- (energy → −10% snapped to step) for the whole session, so the adaptation
-- reason must be stored next to the results it explains.
do $$ begin
  create type session_situation as enum ('time', 'energy', 'pain', 'equipment', 'strong');
exception when duplicate_object then null;
end $$;

alter table workout_sessions
  add column if not exists situation session_situation;

-- ── D4: rest timer survives backgrounding ───────────────────────────────
-- The countdown is derived (now - rest_started_at vs rest_total_seconds), so
-- reopening the app after answering a text resumes mid-count instead of
-- resetting, and the local notification is scheduled from the same two facts.
alter table workout_sessions
  add column if not exists rest_started_at timestamptz,
  add column if not exists rest_total_seconds int
    check (rest_total_seconds is null or rest_total_seconds between 5 and 900);

comment on column workout_sessions.rest_started_at is
  'Set when a rest countdown starts, cleared on skip/expiry. Lives on the '
  'session (not the set) because exactly one rest can run at a time.';

-- ── F4: weight step per exercise ────────────────────────────────────────
-- The session steppers and the "easy → +one step" bump need an increment.
-- NULL on a barbell lift means "derive from plates": 2 × the smallest plate
-- the user owns (snap_to_loadable in v2_0010 is the enforcing function).
-- NULL on a bodyweight lift means no weight control at all (load_type covers
-- the distinction).
alter table exercises
  add column if not exists weight_step_kg numeric(4,2)
    check (weight_step_kg is null or weight_step_kg > 0);

comment on column exercises.weight_step_kg is
  'Smallest sensible load increment. Dumbbell/machine lifts have a fixed step; '
  'barbell lifts leave it NULL and derive 2 x min(plate_sizes_kg); bodyweight '
  'lifts are NULL with load_type bodyweight_reps.';

-- Seed from equipment: dumbbells move in 2 kg pairs, cables/machines in
-- 2.5 kg pin jumps, barbells derive from plates (stay NULL).
update exercises e set weight_step_kg = 2.0
  from exercise_equipment ee join equipment q on q.id = ee.equipment_id
 where ee.exercise_id = e.id and q.slug = 'dumbbell'
   and e.owner_id is null and e.weight_step_kg is null;

update exercises e set weight_step_kg = 2.5
  from exercise_equipment ee join equipment q on q.id = ee.equipment_id
 where ee.exercise_id = e.id and q.slug in ('cable', 'machine')
   and e.owner_id is null and e.weight_step_kg is null
   -- A lift that also uses a barbell keeps NULL (plate-derived wins).
   and not exists (select 1 from exercise_equipment ee2
                     join equipment q2 on q2.id = ee2.equipment_id
                    where ee2.exercise_id = e.id and q2.slug = 'barbell');

-- ── the breaking fix: v2 onboarding does not ask these ──────────────────
-- experience is replaced by has_benched (the thing that actually changes week
-- one); environment by bar + plate inventory (strictly more specific). Both
-- become nullable; plan generation defaults them (v2_0011).
alter table training_profiles alter column experience  drop not null;
alter table training_profiles alter column environment drop not null;

-- D2 (warm-ups): resolved as "accept for v1" — no schema change. Every v2
-- aggregate already filters kind = 'working', so adding a warm-up toggle
-- later is a UI change with zero backfill.
