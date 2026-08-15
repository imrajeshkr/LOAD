-- =============================================================================
-- LOAD — "last time you trained Push Day" must survive a re-plan
--
-- The session comparison matched on workout_sessions.program_day_id. But
-- program_days rows are minted fresh every time bootstrap_user_program runs,
-- so the id is program-scoped and unstable: regenerating a program silently
-- detached every past session from the day it belonged to, and the comparison
-- returned null rather than wrong — the failure mode that hides longest.
--
-- The stable identity of "Push Day" is its label. A lifter who re-plans has
-- not stopped doing Push Day, and should not lose the comparison that tells
-- them whether they are getting stronger at it.
--
-- Extracted into its own function so the next change to this rule doesn't
-- mean re-emitting all of today_plan.
-- =============================================================================

create or replace function last_same_day_totals(
  p_user_id uuid, p_label text, p_before date)
returns jsonb
language sql stable security invoker as $$
  select jsonb_build_object(
           'date',       ws.performed_on,
           'volume_kg',  coalesce(sum(ss.volume_kg), 0),
           'total_reps', coalesce(sum(ss.reps), 0),
           'set_count',  count(*))
    from workout_sessions ws
    join session_exercises se on se.session_id = ws.id
    join session_sets ss on ss.session_exercise_id = se.id
   where ws.user_id = p_user_id
     and ws.status = 'completed'
     and ws.performed_on < p_before
     and ss.is_completed
     -- Matched by label, from either side: the session's own title, or the
     -- label of whichever program day it was linked to at the time.
     and (ws.title = p_label
          or exists (select 1 from program_days d
                      where d.id = ws.program_day_id and d.label = p_label))
   group by ws.performed_on
   order by ws.performed_on desc
   limit 1;
$$;

grant execute on function last_same_day_totals(uuid, text, date) to authenticated;


create or replace function today_plan(p_user_id uuid)
returns jsonb
language plpgsql stable security invoker as $$
declare
  v_today   date := user_today(p_user_id);
  v_program uuid;
  v_day     uuid;
  v_label   text;
  v_session uuid;
  v_status  text;
  v_started timestamptz;
  v_items   jsonb;
  v_now     jsonb;
begin
  select id into v_program
    from programs where user_id = p_user_id and status = 'active';

  if v_program is null then
    return jsonb_build_object('has_plan', false, 'exercises', '[]'::jsonb);
  end if;

  select program_day_id into v_day from scheduled_workouts
   where user_id = p_user_id and program_id = v_program and scheduled_for = v_today
   limit 1;
  if v_day is null then
    select program_day_id into v_day from scheduled_workouts
     where user_id = p_user_id and program_id = v_program
       and status = 'pending' and scheduled_for >= v_today
     order by scheduled_for limit 1;
  end if;
  if v_day is null then
    select id into v_day from program_days
     where program_id = v_program order by ordinal limit 1;
  end if;

  select label into v_label from program_days where id = v_day;

  select id, status::text, started_at into v_session, v_status, v_started
    from workout_sessions
   where user_id = p_user_id and performed_on = v_today
   order by started_at desc limit 1;

  with plan as (
    select pde.ordinal, pde.sets_target, pde.rep_low, pde.rep_high,
           pde.target_weight_kg, pde.rest_seconds,
           e.id as exercise_id, e.name, e.load_type::text as load_type
      from program_day_exercises pde
      join exercises e on e.id = pde.exercise_id
     where pde.program_day_id = v_day
  ),
  prev as (
    select exercise_id, performed_on, sets, volume_kg, total_reps
      from (
        select se.exercise_id, ws.performed_on,
               jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps) order by ss.set_number) as sets,
               sum(ss.volume_kg) as volume_kg,
               sum(ss.reps)      as total_reps,
               row_number() over (partition by se.exercise_id order by ws.performed_on desc) as rn
          from session_sets ss
          join session_exercises se on se.id = ss.session_exercise_id
          join workout_sessions  ws on ws.id = se.session_id
         where se.user_id = p_user_id and ws.performed_on < v_today
           and ws.status = 'completed' and ss.is_completed
         group by se.exercise_id, ws.performed_on
      ) ranked where rn = 1
  ),
  today_sets as (
    select se.exercise_id,
           jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps) order by ss.set_number) as sets,
           count(*) as set_count, sum(ss.volume_kg) as volume_kg, sum(ss.reps) as total_reps
      from session_sets ss
      join session_exercises se on se.id = ss.session_exercise_id
     where se.user_id = p_user_id and se.session_id = v_session and ss.is_completed
     group by se.exercise_id
  )
  select jsonb_agg(
    jsonb_build_object(
      'exercise_id',  p.exercise_id,
      'name',         p.name,
      'load_type',    p.load_type,
      'ordinal',      p.ordinal,
      'sets_target',  p.sets_target,
      'rep_low',      p.rep_low,
      'rep_high',     p.rep_high,
      'rest_seconds', p.rest_seconds,
      'prefill_kg',   coalesce((prev.sets -> -1 ->> 0)::numeric, p.target_weight_kg, 0),
      'prefill_reps', coalesce(p.rep_high, 10),
      'joints',       coalesce((select jsonb_agg(j.slug)
                                  from exercise_joints ej join joints j on j.id = ej.joint_id
                                 where ej.exercise_id = p.exercise_id), '[]'::jsonb),
      'cues',         coalesce((select jsonb_agg(c.body order by c.position)
                                  from exercise_cues c where c.exercise_id = p.exercise_id), '[]'::jsonb),
      'last',         case when prev.exercise_id is null then null else jsonb_build_object(
                         'date', prev.performed_on, 'sets', prev.sets,
                         'volume_kg', prev.volume_kg, 'total_reps', prev.total_reps) end,
      'today',        case when t.exercise_id is null then null else jsonb_build_object(
                         'sets', t.sets, 'set_count', t.set_count,
                         'volume_kg', t.volume_kg, 'total_reps', t.total_reps) end
    ) order by p.ordinal)
    into v_items
    from plan p
    left join prev on prev.exercise_id = p.exercise_id
    left join today_sets t on t.exercise_id = p.exercise_id;

  select jsonb_build_object(
           'set_count',      count(*),
           'volume_kg',      coalesce(sum(ss.volume_kg), 0),
           'total_reps',     coalesce(sum(ss.reps), 0),
           'exercise_count', count(distinct se.exercise_id),
           'started_at',     v_started,
           'elapsed_min',    case when v_started is null then null
                                  else greatest(0, round(extract(epoch from (now() - v_started)) / 60)) end)
    into v_now
    from session_sets ss
    join session_exercises se on se.id = ss.session_exercise_id
   where se.user_id = p_user_id and se.session_id = v_session and ss.is_completed;

  return jsonb_build_object(
    'has_plan',       true,
    'local_date',     v_today,
    'program_day_id', v_day,
    'label',          v_label,
    'session_id',     v_session,
    'session_status', v_status,
    'exercises',      coalesce(v_items, '[]'::jsonb),
    'session_now',    v_now,
    'session_last',   last_same_day_totals(p_user_id, v_label, v_today)
  );
end $$;

grant execute on function today_plan(uuid) to authenticated;
