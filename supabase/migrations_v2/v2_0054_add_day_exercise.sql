-- =============================================================================
-- v2_0054 — add an exercise to a day
--
-- The generator caps a session at 4-6 lifts, which is a rule about what WE
-- prescribe, not a limit on what a lifter may do. Appending is theirs.
-- =============================================================================

create or replace function add_day_exercise(p_program_day_id uuid, p_exercise_id uuid)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ord int;
  v_kg  numeric;
  v_rx  record;
begin
  if v_uid is null then raise exception 'not authorized'; end if;
  if not exists (select 1 from program_days pd join programs p on p.id = pd.program_id
                  where pd.id = p_program_day_id and p.user_id = v_uid) then
    raise exception 'not your program day';
  end if;
  if exists (select 1 from program_day_exercises
              where program_day_id = p_program_day_id and exercise_id = p_exercise_id) then
    return;  -- already there; adding twice is a no-op, not an error
  end if;

  select coalesce(max(ordinal), 0) + 1 into v_ord
    from program_day_exercises where program_day_id = p_program_day_id;

  select * into v_rx from plan_goal_prescription(
    coalesce((select goals[1] from training_profiles
               where user_id = v_uid and valid_to is null), 'build_muscle'));

  select coalesce(
    (select max(db.top_weight_kg) from v_exercise_daily_bests db
      where db.user_id = v_uid and db.exercise_id = p_exercise_id),
    (select e.default_start_kg from exercises e where e.id = p_exercise_id))
    into v_kg;
  if v_kg is not null then v_kg := snap_to_loadable(v_uid, v_kg); end if;

  insert into program_day_exercises
    (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high,
     target_weight_kg, rest_seconds)
  values (p_program_day_id, p_exercise_id, v_ord, 3,
          v_rx.rep_low, v_rx.rep_high, v_kg, v_rx.rest_isolation);
end $$;

revoke all on function add_day_exercise(uuid, uuid) from public;
grant execute on function add_day_exercise(uuid, uuid) to authenticated;

-- =============================================================================
-- browse_exercises — a search across the whole reachable catalogue
--
-- swap_candidates needs a source exercise. Adding needs the whole reachable
-- catalogue instead, so this is a separate RPC rather than swap_candidates
-- with an optional argument.
--
-- A lifter's own exercises bypass the environment and training-age filters:
-- they described it and chose it, so filtering it out of their own list
-- would be the app overruling them about their own gym.
-- =============================================================================

create or replace function browse_exercises(p_query text default null)
returns table (
  exercise_id uuid, slug text, name text, is_core boolean,
  mechanic text, equipment text, muscle text, pattern text,
  min_experience experience_level, demo_path text, is_mine boolean
)
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  with me as (select (select auth.uid()) as uid),
  tp as (select coalesce(t.environment,'commercial_gym') env,
                coalesce(t.experience,'intermediate') exp
           from training_profiles t, me
          where t.user_id = me.uid and t.valid_to is null)
  select distinct on (e.id)
         e.id, e.slug, e.name, e.is_core, e.mechanic,
         (select q.name from exercise_equipment ee join equipment q on q.id = ee.equipment_id
           where ee.exercise_id = e.id order by ee.is_required desc, q.name limit 1),
         (select m.name from exercise_muscles em join muscles m on m.id = em.muscle_id
           where em.exercise_id = e.id and em.role='primary' order by m.name limit 1),
         e.pattern::text, e.min_experience, e.demo_path,
         e.owner_id is not null
    from exercises e, tp, me
   where (e.owner_id is null or e.owner_id = me.uid)
     and e.load_type in ('weight_reps','bodyweight_reps')
     and (p_query is null or e.name ilike '%'||p_query||'%')
     and (e.owner_id is not null or e.min_experience <= tp.exp)
     and (e.owner_id is not null or not exists (
           select 1 from exercise_equipment ee
            where ee.exercise_id = e.id and ee.is_required
              and not exists (select 1 from environment_equipment env
                               where env.equipment_id = ee.equipment_id
                                 and env.environment = tp.env)))
   order by e.id;
$$;

grant execute on function browse_exercises(text) to authenticated;
