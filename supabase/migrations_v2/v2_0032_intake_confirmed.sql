-- =============================================================================
-- v2_0032 — record whether the lifter actually answered the intake questions
--
-- Spec §10 promised: "Existing users default to intermediate + commercial_gym
-- (today's implicit behaviour) and get prompted once in Profile." The default
-- shipped (v2_0022, v2_0031); the prompt never did.
--
-- That was tolerable while nothing read `experience`. It is not tolerable now:
-- v2_0029 uses it to filter the catalog by training age, and v2_0030 uses it to
-- pick a whole progression scheme. A genuine beginner silently defaulted to
-- 'intermediate' is handed intermediate lifts and double progression instead of
-- linear — the exact lifter for whom the difference matters most.
--
-- The missing piece is not the value, it is knowing where the value came from.
-- `intermediate` reads identically whether a user chose it or a migration
-- guessed it. This column separates the two.
--
-- Default false, and that default does the work: an app build released before
-- Plan 01 omits the key, so its rows land unconfirmed and the user gets asked.
-- Current onboarding sets it true explicitly. Same mechanism as v2_0031.
--
-- Existing rows all become unconfirmed. Some of those users did answer, and
-- will be asked once more than strictly necessary — with 8 profiles that costs
-- a single tap, while under-prompting leaves a beginner on the wrong scheme
-- indefinitely. Erring toward asking is the cheaper mistake.
-- =============================================================================

alter table training_profiles
  add column if not exists intake_confirmed boolean not null default false;

comment on column training_profiles.intake_confirmed is
  'True only when the lifter answered the experience/environment steps '
  'themselves. False means the value came from a default or a backfill and '
  'Profile should ask once. Never set this true on the user''s behalf.';
