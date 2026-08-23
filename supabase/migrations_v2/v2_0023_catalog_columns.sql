-- =============================================================================
-- v2_0023 — columns the catalog import needs
--
-- Adds the metadata that distinguishes a prescribable exercise from a merely
-- browsable one, plus the fields the dataset already carries and the generator
-- currently fakes.
--
--   min_experience  a beginner is never auto-given an 'advanced' lift
--   mechanic        compound | isolation — the compound-first signal the
--                   generator currently approximates with default_rep_low
--   force           push | pull | static (from the dataset)
--   is_core         FALSE = browse/swap only, never auto-selected. Only rows
--                   with authored joint stress + muscle contributions may be
--                   prescribed, because injury routing depends on them.
--   source          provenance, so an import can be re-run or rolled back
--
-- Existing rows keep their behaviour: the 36 hand-authored exercises are
-- explicitly promoted to is_core = true at the end, since they already carry
-- joint stress, contributions and start loads.
-- =============================================================================

alter table exercises
  add column if not exists min_experience experience_level not null default 'beginner',
  add column if not exists mechanic       text,
  add column if not exists force          text,
  add column if not exists is_core        boolean not null default false,
  add column if not exists source         text;

alter table exercises drop constraint if exists exercises_mechanic_valid;
alter table exercises add constraint exercises_mechanic_valid
  check (mechanic is null or mechanic in ('compound', 'isolation'));

alter table exercises drop constraint if exists exercises_force_valid;
alter table exercises add constraint exercises_force_valid
  check (force is null or force in ('push', 'pull', 'static'));

-- The generator may only auto-select Core rows. Partial index because that is
-- the only slice it ever scans.
create index if not exists exercises_core_pattern_idx
  on exercises (pattern) where owner_id is null and is_core;

-- Everything that already existed is Core: hand-authored, enriched, illustrated.
update exercises
   set is_core = true,
       source  = coalesce(source, 'load')
 where owner_id is null and source is null;
