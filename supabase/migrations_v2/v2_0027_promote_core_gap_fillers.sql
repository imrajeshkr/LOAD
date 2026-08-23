-- =============================================================================
-- v2_0027 — promote 10 imported exercises to Core, closing the two real gaps
--
-- Core means "the generator may prescribe this unprompted", which requires
-- authored joint stress (injury routing depends on it), muscle contribution,
-- rep ranges and a sane starting load. The import left everything Extended;
-- this promotes a deliberately small set chosen to close specific holes:
--
--   bodyweight_only — had 3 prescribable exercises and ZERO legs. A Leg day
--                     generated empty, which is why the "No equipment" option
--                     is currently hidden in onboarding.
--   home_gym        — had no rhomboid, rear-delt or calf option at all (every
--                     one needed a cable or machine), so a home Pull day came
--                     out as 2 exercises.
--
-- Joint stress uses the same vocabulary as the hand-authored 36:
--   mild     = loaded but not a limiting factor
--   moderate = meaningfully stressed; warn when the joint is flagged
--   severe   = do not prescribe when that joint is flagged
-- Values below are deliberately conservative: where a movement is commonly
-- implicated in joint pain it is marked severe rather than moderate, because
-- the cost of over-restricting is a duller plan and the cost of under-
-- restricting is an injury.
-- =============================================================================

-- ── rep ranges + starting loads ──────────────────────────────────────────────
update exercises set default_rep_low = 8,  default_rep_high = 15, default_start_kg = null
 where owner_id is null and slug in ('bodyweight-squat','butt-lift-bridge',
                                     'single-leg-glute-bridge','natural-glute-ham-raise',
                                     'bench-dips','chin-up');

update exercises set default_rep_low = 8,  default_rep_high = 12, default_start_kg = 10, weight_step_kg = 2.5
 where owner_id is null and slug in ('bent-over-two-dumbbell-row','one-arm-dumbbell-row');

update exercises set default_rep_low = 12, default_rep_high = 20, default_start_kg = 5,  weight_step_kg = 1.25
 where owner_id is null and slug in ('reverse-flyes');

update exercises set default_rep_low = 10, default_rep_high = 20, default_start_kg = 10, weight_step_kg = 2.5
 where owner_id is null and slug in ('standing-dumbbell-calf-raise');

-- ── joint stress ─────────────────────────────────────────────────────────────
-- (exercise slug, joint slug, stress level)
insert into exercise_joints (exercise_id, joint_id, stress_level)
select e.id, j.id, v.stress::severity_level
  from (values
    -- bodyweight legs: the gap that made "No equipment" generate empty days
    ('bodyweight-squat',            'knee',      'moderate'),
    ('bodyweight-squat',            'hip',       'moderate'),
    ('bodyweight-squat',            'lumbar',    'mild'),
    ('butt-lift-bridge',            'hip',       'mild'),
    ('butt-lift-bridge',            'lumbar',    'mild'),
    ('single-leg-glute-bridge',     'hip',       'mild'),
    ('single-leg-glute-bridge',     'lumbar',    'mild'),
    -- eccentric-heavy on the hamstring; a flagged hamstring should exclude it
    ('natural-glute-ham-raise',     'hamstring', 'severe'),
    ('natural-glute-ham-raise',     'knee',      'moderate'),
    -- bench dips put the shoulder in extension under load: a classic
    -- impingement driver, so severe rather than moderate
    ('bench-dips',                  'shoulder',  'severe'),
    ('bench-dips',                  'elbow',     'moderate'),
    ('chin-up',                     'shoulder',  'moderate'),
    ('chin-up',                     'elbow',     'moderate'),
    -- home-gym gap fillers
    ('bent-over-two-dumbbell-row',  'lumbar',    'moderate'),
    ('bent-over-two-dumbbell-row',  'shoulder-blade', 'mild'),
    ('bent-over-two-dumbbell-row',  'elbow',     'mild'),
    ('one-arm-dumbbell-row',        'lumbar',    'mild'),
    ('one-arm-dumbbell-row',        'shoulder-blade', 'mild'),
    ('one-arm-dumbbell-row',        'elbow',     'mild'),
    ('reverse-flyes',               'shoulder',  'mild'),
    ('reverse-flyes',               'shoulder-blade', 'mild'),
    ('standing-dumbbell-calf-raise','ankle',     'moderate'),
    ('standing-dumbbell-calf-raise','calf',      'moderate')
  ) as v(ex, joint, stress)
  join exercises e on e.slug = v.ex and e.owner_id is null
  join joints    j on j.slug = v.joint
on conflict do nothing;

-- ── promote ──────────────────────────────────────────────────────────────────
-- Only rows that actually received joint stress above are promoted, so a typo'd
-- slug silently fails closed (stays Extended) rather than becoming prescribable
-- with no injury data.
update exercises e set is_core = true
 where e.owner_id is null
   and e.slug in ('bodyweight-squat','butt-lift-bridge','single-leg-glute-bridge',
                  'natural-glute-ham-raise','bench-dips','chin-up',
                  'bent-over-two-dumbbell-row','one-arm-dumbbell-row',
                  'reverse-flyes','standing-dumbbell-calf-raise')
   and exists (select 1 from exercise_joints ej where ej.exercise_id = e.id);
