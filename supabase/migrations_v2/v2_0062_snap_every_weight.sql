-- =============================================================================
-- v2_0062 — every prescribed weight lands on something you can actually pick up
--
-- A dumbbell bench press was prescribed at 8.8 kg and a lateral raise at 3.2.
-- No gym has those. They come from the "never benched" fallback, which takes
-- 40% of the catalogue default and rounds to one decimal:
--
--     round(22.00 * 0.4, 1) = 8.8      round(8.00 * 0.4, 1) = 3.2
--
-- One decimal place is not an increment — it is just fewer digits.
--
-- The generator already snapped BARBELL weights (bar + symmetric plates) and
-- left everything else alone, because snap_to_loadable only understands bars.
-- Worse, train_screen's progression branches call snap_to_loadable for every
-- lift, and its first line is `if p_kg <= bar then return bar` — so a dumbbell
-- press progressing from 8.8 kg would have been handed 20 kg, the weight of a
-- barbell it does not use.
--
-- snap_weight knows the exercise: bars keep plate maths, everything else snaps
-- to the increment the catalogue already declares (dumbbell 2, machine 2.5),
-- and bodyweight stays null. Both paths land on a half-kilo grid, which is the
-- rule the app promises the lifter.
--
-- Enforced by a trigger rather than by editing each of the fifteen callers.
-- The generator, swap, add-exercise and any future writer all go through the
-- same table, so the table is where the guarantee belongs.
-- =============================================================================

create or replace function snap_weight(
  p_user_id     uuid,
  p_exercise_id uuid,
  p_kg          numeric
)
returns numeric
language plpgsql stable security invoker as $$
declare
  v_load text;
  v_bb   boolean;
  v_step numeric;
begin
  if p_kg is null then return null; end if;

  select e.load_type,
         exists (select 1 from exercise_equipment ee
                   join equipment q on q.id = ee.equipment_id
                  where ee.exercise_id = e.id and q.slug = 'barbell')
    into v_load, v_bb
    from exercises e where e.id = p_exercise_id;

  if v_load is null then return round(p_kg * 2) / 2; end if;   -- unknown lift
  if v_load = 'bodyweight_reps' then return null; end if;
  if v_bb then return snap_to_loadable(p_user_id, p_kg); end if;

  v_step := coalesce(resolved_weight_step(p_user_id, p_exercise_id), 2.5);
  if v_step <= 0 then return round(p_kg * 2) / 2; end if;

  -- Nearest real increment, and never below one of them: half a dumbbell is
  -- not a thing you can take off the rack.
  return greatest(v_step, round(p_kg / v_step) * v_step);
end $$;

grant execute on function snap_weight(uuid, uuid, numeric) to authenticated;

-- ── the guarantee, at the table ─────────────────────────────────────────────
create or replace function _snap_pde_weight()
returns trigger
language plpgsql as $$
declare v_uid uuid;
begin
  if new.target_weight_kg is null then return new; end if;
  select pr.user_id into v_uid
    from program_days pd
    join programs pr on pr.id = pd.program_id
   where pd.id = new.program_day_id;
  if v_uid is null then return new; end if;
  new.target_weight_kg := snap_weight(v_uid, new.exercise_id, new.target_weight_kg);
  return new;
end $$;

drop trigger if exists snap_pde_weight on program_day_exercises;
create trigger snap_pde_weight
  before insert or update of target_weight_kg, exercise_id
  on program_day_exercises
  for each row execute function _snap_pde_weight();

-- ── the read path ───────────────────────────────────────────────────────────
-- train_screen computes prefill_kg live, so the trigger cannot reach it. Rather
-- than paste twelve kilobytes of function back into this file and risk losing
-- a patch made since, take the definition that is actually installed and
-- rewrite only the three snap calls in it. The count is asserted: if the
-- function has changed shape, this fails loudly instead of silently doing
-- nothing.
do $$
declare
  v_src  text;
  v_from text := 'snap_to_loadable(p_user_id,';
  v_to   text := 'snap_weight(p_user_id, p.exercise_id,';
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'train_screen' and p.prokind = 'f';
  if v_src is null then raise exception 'train_screen not found'; end if;

  v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
  if v_hits <> 3 then
    raise exception 'expected 3 snap_to_loadable calls in train_screen, found %', v_hits;
  end if;

  execute replace(v_src, v_from, v_to);
end $$;

-- ── bring the weights already on the board into line ────────────────────────
update program_day_exercises set target_weight_kg = target_weight_kg where target_weight_kg is not null;
