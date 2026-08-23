-- =============================================================================
-- v2_0031 — stop `experience` and `environment` from ever landing NULL again
--
-- v2_0022 backfilled the NULLs that existed at the time. That was a one-time
-- repair, and it did not hold: a profile created 2026-08-23 05:29 UTC came in
-- with goals, split_preference and days_per_week set but both of these NULL.
--
-- The cause is not a bug in the current client. Onboarding sends both fields,
-- and `OnboardingDraft` makes them non-nullable and required, so the shipped
-- app cannot produce this row. It came from an OLDER build — released before
-- Plan 01 added the two intake steps — which simply has no such keys in its
-- insert payload. Every install still on an old version re-opens the hole, and
-- no amount of client-side fixing closes it, because we do not control when
-- users update.
--
-- So the guarantee moves into the column. PostgREST applies a column DEFAULT
-- whenever the request body omits the key, which is exactly what an old client
-- does — the row lands with a sane value instead of NULL, with no client change
-- and no release needed.
--
-- Deliberately NOT NOT NULL. A DEFAULT only covers an omitted key; an explicit
-- `"experience": null` would still write NULL, and NOT NULL would turn that
-- into a failed insert — a user unable to finish onboarding. No known client
-- sends an explicit null, but trading a silent degradation for a hard onboarding
-- failure is the wrong way round when the generator already coalesces NULLs to
-- these same values. The standing assertion in
-- supabase/tests/v2_0022_backfill_test.sql is what catches a regression here;
-- it is what caught this one.
--
-- The defaults match what bootstrap_user_program() already coalesces to, so
-- behaviour is unchanged for anyone — this only makes the stored data honest.
-- =============================================================================

alter table training_profiles
  alter column experience  set default 'intermediate',
  alter column environment set default 'commercial_gym';

-- Repair what the gap let through since v2_0022.
update training_profiles
   set experience = 'intermediate'
 where valid_to is null and experience is null;

update training_profiles
   set environment = 'commercial_gym'
 where valid_to is null and environment is null;

do $$
declare v_left int;
begin
  select count(*) into v_left from training_profiles
   where valid_to is null and (experience is null or environment is null);
  if v_left > 0 then
    raise exception 'v2_0031: % current profile(s) still NULL', v_left;
  end if;
end $$;
