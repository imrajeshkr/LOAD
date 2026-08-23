-- =============================================================================
-- v2_0028 — author `mechanic` for the original 36 Core exercises
--
-- v2_0023 added the column; only the 10 rows later promoted from the import
-- carry a value, because the dataset supplied one. The hand-authored 36 are all
-- NULL, so any "compounds open the session" ordering has nothing to sort on and
-- degenerates to slug order.
--
-- The distinction is mechanical, not a matter of taste: compound = the load
-- crosses more than one joint. Hip thrust and RDL are single-plane but
-- multi-joint under load, so they count as compound. Plank is isometric core
-- work with no joint travel — isolation is the honest bucket for it.
-- =============================================================================

update exercises set mechanic = 'compound'
 where owner_id is null and is_core and mechanic is null and slug in (
   'back-squat', 'barbell-row', 'bench-press', 'bulgarian-split-squat',
   'chest-supported-row', 'db-bench-press', 'deadlift', 'dumbbell-row',
   'floor-press', 'front-squat', 'goblet-squat', 'hip-thrust',
   'incline-db-press', 'landmine-press', 'lat-pulldown', 'leg-press',
   'machine-chest-press', 'overhead-press', 'pull-up', 'push-up',
   'romanian-deadlift', 'seated-cable-row', 'walking-lunge'
 );

update exercises set mechanic = 'isolation'
 where owner_id is null and is_core and mechanic is null and slug in (
   'barbell-curl', 'cable-crunch', 'cable-fly', 'calf-raise', 'face-pull',
   'hammer-curl', 'hanging-leg-raise', 'lateral-raise', 'leg-curl',
   'leg-extension', 'overhead-tricep-ext', 'plank', 'tricep-pushdown'
 );

-- Fail loudly rather than silently shipping a half-tagged catalog: the
-- generator's compound-first ordering is only meaningful if every Core row is
-- classified.
do $$
declare v_missing int;
begin
  select count(*) into v_missing
    from exercises where owner_id is null and is_core and mechanic is null;
  if v_missing > 0 then
    raise exception 'v2_0028: % Core exercise(s) still have no mechanic', v_missing;
  end if;
end $$;
