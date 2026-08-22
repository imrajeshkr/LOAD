-- =============================================================================
-- v2_0022 — backfill experience / environment for existing users
--
-- Both columns existed but were never collected. The generator already
-- coalesced environment to commercial_gym, and its fixed prescriptions match an
-- intermediate lifter — so these defaults encode today's behaviour exactly and
-- change nobody's plan. New users answer for real (v2_0021 onboarding steps).
-- Idempotent: only fills NULLs.
-- =============================================================================

update training_profiles
   set experience = 'intermediate'
 where experience is null;

update training_profiles
   set environment = 'commercial_gym'
 where environment is null;
