-- =============================================================================
-- v2_0025 — real experience levels for the original 36 Core exercises
--
-- v2_0023 added min_experience with a 'beginner' default, which swept in every
-- pre-existing row — so Front Squat, Deadlift and Hanging Leg Raise were all
-- tagged beginner. Once the generator honours min_experience (Plan 03), that
-- would hand a novice lifts they have no business being prescribed.
--
-- What the tiers mean here:
--   beginner     — a novice program legitimately opens with this. Includes the
--                  barbell staples (squat, bench, deadlift, press, row): every
--                  serious novice program prescribes them from week one, and
--                  withholding them would make beginner plans worse, not safer.
--   intermediate — needs a base of strength, skill or mobility first, or is
--                  simply not achievable cold (an untrained lifter usually
--                  cannot do a single pull-up).
--   advanced     — high mobility or technical demand; wrong to auto-prescribe.
--
-- Only the 36 hand-authored Core rows are touched. Imported Extended rows keep
-- the level the dataset assigned them.
-- =============================================================================

-- Needs a base first: skill, mobility, or raw strength.
update exercises set min_experience = 'intermediate'
 where owner_id is null and is_core and slug in (
   'bulgarian-split-squat',   -- unilateral balance + knee control under load
   'pull-up',                 -- most untrained lifters cannot do one
   'hanging-leg-raise',       -- needs grip endurance and core control
   'landmine-press',          -- awkward groove, easy to compensate with the back
   'floor-press',             -- partial ROM, needs press technique to be useful
   'overhead-tricep-ext',     -- elbow-unfriendly if the press pattern is not owned
   'walking-lunge'            -- loaded unilateral, high fatigue and balance cost
 );

-- High mobility / technical demand. The dataset independently rates the front
-- squat 'expert'; front-rack mobility is the binding constraint.
update exercises set min_experience = 'advanced'
 where owner_id is null and is_core and slug in ('front-squat');

-- Everything else stays 'beginner' — machines, cables, dumbbells, bodyweight,
-- and the barbell staples that novice programming is built on.
