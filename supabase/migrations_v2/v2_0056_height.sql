-- =============================================================================
-- v2_0056 — store height, so BMI can be shown
--
-- Height lives on `profiles` rather than `body_measurements` or
-- `training_profiles`: it is an attribute of the person, not a measurement
-- that trends or a setting that changes with a training block. Storing it
-- alongside weigh-ins would invite a chart of it, which would be noise.
--
-- Nullable on purpose. Every existing account has no height and must keep
-- working — BMI is additional context, never a prerequisite, so the screens
-- that show it simply omit it when height is unknown.
-- =============================================================================

alter table profiles
  add column if not exists height_cm numeric;

alter table profiles drop constraint if exists profiles_height_cm_check;
alter table profiles add constraint profiles_height_cm_check
  check (height_cm is null or (height_cm >= 90 and height_cm <= 250));

comment on column profiles.height_cm is
  'Standing height in centimetres. Null when never asked — BMI is context, '
  'not a prerequisite, so every consumer must tolerate its absence.';
