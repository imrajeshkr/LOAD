-- =============================================================================
-- LOAD — context-pack RPCs
--
-- The coach's context is assembled from these rather than from raw rows. Each
-- one returns something already shaped for a prompt line, so the Edge Function
-- does formatting and nothing else, and so the expensive joins stay in the
-- database where the planner can see them.
-- =============================================================================

-- The catalog this lifter can actually use: filtered to equipment their
-- environment has, and flagged where a movement stresses a joint they have
-- reported. The injury rule is a WHERE clause and a computed column here —
-- not an instruction the model is asked to remember.
-- Two distinct outcomes, deliberately: a flagged joint makes a movement worth
-- a WARNING far more often than it makes it forbidden. A moderate shoulder
-- niggle should not rule out benching — it should surface a caution and offer
-- a swap, which is exactly what the app's own UI already does. Only the
-- combinations below are hard exclusions:
--
--     exercise stress  ×  constraint severity   →  outcome
--     severe              any                      contraindicated
--     moderate            severe                   contraindicated
--     moderate            mild / moderate          caution
--     mild                severe                   caution
--     mild                mild / moderate          (nothing)
create or replace function coach_catalog(p_user_id uuid)
returns table (
  exercise_id     uuid,
  name            text,
  pattern         text,
  muscles         text,
  contraindicated boolean,
  caution         text,
  substitute      text
)
language sql stable
security invoker as $$
  with env as (
    select environment from training_profiles
     where user_id = p_user_id and valid_to is null
  ),
  usable as (
    select e.id, e.name, e.pattern
      from exercises e
     where e.owner_id is null
       and not exists (
             select 1 from exercise_equipment ee
              where ee.exercise_id = e.id and ee.is_required
                and not exists (
                      select 1 from environment_equipment env_eq, env
                       where env_eq.equipment_id = ee.equipment_id
                         and env_eq.environment = env.environment))
  ),
  -- One row per (exercise, flagged joint), carrying how hard the clash is.
  clash as (
    select ej.exercise_id,
           uc.label,
           j.name as joint_name,
           (ej.stress_level = 'severe')
             or (ej.stress_level = 'moderate' and uc.severity = 'severe') as is_block,
           (ej.stress_level = 'moderate')
             or (ej.stress_level = 'mild' and uc.severity = 'severe')     as is_caution
      from exercise_joints ej
      join user_constraints uc
        on uc.joint_id = ej.joint_id
       and uc.user_id  = p_user_id
       and uc.active_to is null
      join joints j on j.id = ej.joint_id
  ),
  rolled as (
    select exercise_id,
           bool_or(is_block)   as blocked,
           bool_or(is_caution) as cautioned,
           min(joint_name)     as joint_name
      from clash
     group by exercise_id
  )
  select u.id,
         u.name,
         u.pattern,
         (select string_agg(m.name, ', ' order by em.role, m.name)
            from exercise_muscles em
            join muscles m on m.id = em.muscle_id
           where em.exercise_id = u.id and em.role = 'primary'),
         coalesce(r.blocked, false),
         case
           when coalesce(r.blocked, false)   then 'avoid — ' || r.joint_name
           when coalesce(r.cautioned, false) then 'watch your ' || lower(r.joint_name)
           else null
         end,
         -- Only offer a substitute that isn't itself blocked.
         (select alt.name
            from exercise_alternatives ea
            join exercises alt on alt.id = ea.alternative_id
           where ea.exercise_id = u.id
             and ea.reason = 'joint_friendly'
             and not exists (select 1 from rolled rb
                              where rb.exercise_id = alt.id and rb.blocked)
           order by ea.rank
           limit 1)
    from usable u
    left join rolled r on r.exercise_id = u.id
   order by u.pattern nulls last, u.name;
$$;

grant execute on function coach_catalog(uuid) to authenticated;


-- Hard sets per muscle over the last four weeks — the dose metric the coach
-- reasons about, pre-summed so the model never counts sets itself.
create or replace function coach_weekly_volume(p_user_id uuid)
returns table (muscle text, sets numeric)
language sql stable
security invoker as $$
  select m.name, round(sum(v.effective_sets), 1)
    from v_weekly_muscle_volume v
    join muscles m on m.id = v.muscle_id
   where v.user_id = p_user_id
     and v.week_start >= (current_date - interval '4 weeks')
   group by m.name
  having sum(v.effective_sets) > 0
   order by 2 desc
   limit 12;
$$;

grant execute on function coach_weekly_volume(uuid) to authenticated;


-- Per-exercise history for the coach's drill-down tool. Returns one line per
-- session, newest first, with the sets collapsed into a readable summary.
create or replace function coach_exercise_history(
  p_user_id uuid, p_exercise_id uuid, p_weeks int default 8)
returns table (
  performed_on date,
  sets_summary text,
  top_weight_kg numeric,
  best_e1rm_kg numeric
)
language sql stable
security invoker as $$
  select ws.performed_on,
         string_agg(ss.weight_kg || 'x' || ss.reps, ', ' order by ss.set_number),
         max(ss.weight_kg),
         max(ss.e1rm_kg)
    from session_sets ss
    join session_exercises se on se.id = ss.session_exercise_id
    join workout_sessions  ws on ws.id = se.session_id
   where se.user_id = p_user_id
     and se.exercise_id = p_exercise_id
     and ws.status = 'completed'
     and ws.performed_on >= (current_date - (p_weeks || ' weeks')::interval)
     and ss.is_completed
   group by ws.performed_on
   order by ws.performed_on desc
   limit 12;
$$;

grant execute on function coach_exercise_history(uuid, uuid, int) to authenticated;


-- Suggested next load. Deterministic: double progression — if every working
-- set in the most recent session hit the top of the rep range, add one
-- increment, otherwise hold. The model decides *whether* to apply this and
-- explains why; the number comes from here.
create or replace function coach_next_load(p_user_id uuid, p_exercise_id uuid)
returns table (suggested_kg numeric, rationale text)
language plpgsql stable
security invoker as $$
declare
  v_last     record;
  v_step     numeric;
  v_rep_high int;
begin
  select coalesce(weight_increment_kg, 2.5) into v_step
    from user_preferences where user_id = p_user_id;
  v_step := coalesce(v_step, 2.5);

  select coalesce(max(pde.rep_high), 12) into v_rep_high
    from program_day_exercises pde
    join program_days d on d.id = pde.program_day_id
    join programs p on p.id = d.program_id
   where p.user_id = p_user_id and p.status = 'active'
     and pde.exercise_id = p_exercise_id;

  select ws.performed_on,
         max(ss.weight_kg) as top_weight,
         min(ss.reps)      as min_reps,
         count(*)          as n_sets
    into v_last
    from session_sets ss
    join session_exercises se on se.id = ss.session_exercise_id
    join workout_sessions  ws on ws.id = se.session_id
   where se.user_id = p_user_id and se.exercise_id = p_exercise_id
     and ws.status = 'completed' and ss.is_completed
     and ss.kind in ('working', 'amrap', 'failure')
   group by ws.performed_on
   order by ws.performed_on desc
   limit 1;

  if v_last is null then
    return query select null::numeric,
      'No completed sets on record for this exercise yet — start conservative and log it.'::text;
    return;
  end if;

  if v_last.min_reps >= v_rep_high then
    return query select (v_last.top_weight + v_step)::numeric,
      format('Hit %s+ reps on every set at %s kg on %s. Add one increment (%s kg).',
             v_rep_high, v_last.top_weight, v_last.performed_on, v_step)::text;
  else
    return query select v_last.top_weight::numeric,
      format('Last session at %s kg topped out at %s reps, short of %s. Hold the load and add reps.',
             v_last.top_weight, v_last.min_reps, v_rep_high)::text;
  end if;
end $$;

grant execute on function coach_next_load(uuid, uuid) to authenticated;
