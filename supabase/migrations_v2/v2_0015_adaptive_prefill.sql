-- =============================================================================
-- v2_0015 — adaptive load prefill (double progression + RIR autoregulation)
--
-- train_screen previously prefilled each lift at last session's exact weight ×
-- the top of the rep range — flat, and blind to how hard the last session was.
-- Replace that with a next-target computed from the last completed session's
-- top set and effort:
--
--   no history        → plan weight × rep_low          (conservative start)
--   auto-filled last  → same weight × rep_low          (don't build on a guess)
--   ground out (RIR0) → same weight × same reps        (repeat, earn it)
--   hit top + RIR>=1  → +1 loadable step × rep_low      (graduate the range)
--   easy (RIR>=2)     → same weight × +2 reps (<=top)  (reps before weight)
--   otherwise         → same weight × +1 rep  (<=top)  (steady climb)
--
-- Recomputed every session from the last ACTUAL top set, so it self-corrects:
-- exceed the target and weight bumps next time; fall short and it holds.
--
-- Only the `prev` CTE and prefill_kg/prefill_reps change vs v2_0010; the rest
-- of train_screen (week strip, upcoming, today progress) is verbatim.
-- =============================================================================

create or replace function train_screen(p_user_id uuid)
returns jsonb
language plpgsql stable security invoker as $$
declare
  v_today    date := user_today(p_user_id);
  v_week0    date := date_trunc('week', v_today)::date;   -- Monday
  v_weekdays smallint[];
  v_sched    record;
  v_session  record;
  v_items    jsonb;
  v_prog_start date;
begin
  select training_weekdays into v_weekdays
    from training_profiles where user_id = p_user_id and valid_to is null;

  select created_at::date into v_prog_start
    from profiles where id = p_user_id;

  select sw.id, sw.program_day_id, pd.label into v_sched
    from scheduled_workouts sw
    join program_days pd on pd.id = sw.program_day_id
   where sw.user_id = p_user_id and sw.scheduled_for = v_today
   limit 1;

  select ws.id, ws.status::text, ws.started_at into v_session
    from workout_sessions ws
   where ws.user_id = p_user_id and ws.performed_on = v_today
   order by ws.started_at desc limit 1;

  if v_sched.program_day_id is not null then
    with plan as (
      select pde.ordinal, pde.sets_target, pde.rep_low, pde.rep_high,
             pde.target_weight_kg, pde.rest_seconds,
             e.id as exercise_id, e.name, e.load_type::text as load_type,
             e.demo_path
        from program_day_exercises pde
        join exercises e on e.id = pde.exercise_id
       where pde.program_day_id = v_sched.program_day_id
    ),
    -- Last completed session per exercise, with the facts the progression
    -- rules need. sess_top is the heaviest working weight; `is not distinct
    -- from` lets bodyweight lifts (null weight) still resolve a top set.
    prev_raw as (
      select se.exercise_id, se.id as se_id,
             se.effort::text as effort, se.is_unconfirmed as unconfirmed,
             ws.performed_on, ss.weight_kg, ss.reps, ss.rir, ss.set_number,
             max(ss.weight_kg) over (partition by se.id) as sess_top
        from session_sets ss
        join session_exercises se on se.id = ss.session_exercise_id
        join workout_sessions  ws on ws.id = se.session_id
       where se.user_id = p_user_id and ws.performed_on < v_today
         and ws.status = 'completed' and ss.is_completed and ss.kind = 'working'
    ),
    prev as (
      select exercise_id, sets, top_kg, top_reps, last_rir, effort, unconfirmed
      from (
        select exercise_id, effort, unconfirmed, performed_on,
               jsonb_agg(jsonb_build_array(weight_kg, reps) order by set_number) as sets,
               max(weight_kg) as top_kg,
               max(reps) filter (where weight_kg is not distinct from sess_top) as top_reps,
               (array_agg(rir order by set_number desc))[1] as last_rir,
               row_number() over (partition by exercise_id order by performed_on desc) as rn
          from prev_raw
         group by exercise_id, se_id, effort, unconfirmed, performed_on, sess_top
      ) r where rn = 1
    ),
    today_progress as (
      select se.exercise_id, count(*) as done
        from session_sets ss
        join session_exercises se on se.id = ss.session_exercise_id
       where se.session_id = v_session.id and ss.is_completed and ss.kind = 'working'
       group by se.exercise_id
    )
    select jsonb_agg(jsonb_build_object(
      'exercise_id',  p.exercise_id,
      'name',         p.name,
      'load_type',    p.load_type,
      'ordinal',      p.ordinal,
      'sets_target',  p.sets_target,
      'rep_low',      p.rep_low,
      'rep_high',     p.rep_high,
      'rest_seconds', p.rest_seconds,
      'demo_path',    p.demo_path,
      'weight_step',  resolved_weight_step(p_user_id, p.exercise_id),
      -- Adaptive weight (double progression): only rises when the top of the
      -- range was reached with a rep in reserve. Bodyweight lifts (null top_kg)
      -- fall through to the plan target / 0.
      'prefill_kg', coalesce(
        case
          when prev.exercise_id is null then p.target_weight_kg
          when prev.top_kg is null      then p.target_weight_kg
          when prev.top_reps >= p.rep_high and coalesce(prev.last_rir, 0) >= 1
               and prev.effort is distinct from 'all'
            then snap_to_loadable(p_user_id,
                   prev.top_kg + coalesce(resolved_weight_step(p_user_id, p.exercise_id), 2.5))
          else prev.top_kg
        end, p.target_weight_kg, 0),
      -- Adaptive reps: bottom of range after a weight bump or a fresh/auto
      -- start; otherwise creep up toward the top (faster on an easy day).
      'prefill_reps', coalesce(
        case
          when prev.exercise_id is null then p.rep_low
          when prev.unconfirmed         then p.rep_low
          when prev.effort = 'all' or coalesce(prev.last_rir, 0) = 0
            then coalesce(prev.top_reps, p.rep_low)
          when prev.top_reps >= p.rep_high and coalesce(prev.last_rir, 0) >= 1
            then p.rep_low
          when coalesce(prev.last_rir, 0) >= 2 or prev.effort = 'easy'
            then least(prev.top_reps + 2, p.rep_high)
          else least(coalesce(prev.top_reps, p.rep_low) + 1, p.rep_high)
        end, p.rep_high, 10),
      'last_sets',    prev.sets,
      'done_sets',    coalesce(tp.done, 0),
      'joints',       coalesce((select jsonb_agg(j.slug)
                                  from exercise_joints ej
                                  join joints j on j.id = ej.joint_id
                                 where ej.exercise_id = p.exercise_id), '[]'::jsonb),
      'cues',         coalesce((select jsonb_agg(c.body order by c.position)
                                  from exercise_cues c
                                 where c.exercise_id = p.exercise_id), '[]'::jsonb)
    ) order by p.ordinal)
      into v_items
      from plan p
      left join prev on prev.exercise_id = p.exercise_id
      left join today_progress tp on tp.exercise_id = p.exercise_id;
  end if;

  return jsonb_build_object(
    'today',          v_today,
    'is_rest',        v_sched.program_day_id is null,
    'label',          v_sched.label,
    'session_id',     v_session.id,
    'session_status', v_session.status,
    'started_at',     v_session.started_at,
    'paused',         is_training_paused(p_user_id),
    'exercises',      coalesce(v_items, '[]'::jsonb),
    'week', (
      select jsonb_agg(jsonb_build_object(
        'date',    d::date,
        'dow',     extract(isodow from d)::int,
        'label',   (select pd2.label from scheduled_workouts sw3
                     join program_days pd2 on pd2.id = sw3.program_day_id
                    where sw3.user_id = p_user_id and sw3.scheduled_for = d::date
                    limit 1),
        'planned', (exists (select 1 from scheduled_workouts sw2
                            where sw2.user_id = p_user_id
                              and sw2.scheduled_for = d::date)
                   or extract(isodow from d)::int = any (coalesce(v_weekdays, '{}')))
                   and d::date >= coalesce(v_prog_start, d::date),
        'trained', exists (select 1 from workout_sessions ws2
                            where ws2.user_id = p_user_id
                              and ws2.performed_on = d::date
                              and ws2.status = 'completed'),
        'is_today', d::date = v_today
      ) order by d)
      from generate_series(v_week0, v_week0 + 6, interval '1 day') d
    ),
    'upcoming', (
      select coalesce(jsonb_agg(u order by (u->>'on')), '[]'::jsonb) from (
        select jsonb_build_object(
                 'on', sw.scheduled_for, 'label', pd.label,
                 'lift_count', (select count(*) from program_day_exercises pde
                                 where pde.program_day_id = pd.id),
                 'exercises', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'name',             e.name,
                            'load_type',        e.load_type::text,
                            'sets_target',      pde.sets_target,
                            'rep_low',          pde.rep_low,
                            'rep_high',         pde.rep_high,
                            'target_weight_kg', pde.target_weight_kg
                          ) order by pde.ordinal), '[]'::jsonb)
                     from program_day_exercises pde
                     join exercises e on e.id = pde.exercise_id
                    where pde.program_day_id = pd.id
                 )
               ) as u
          from scheduled_workouts sw
          join program_days pd on pd.id = sw.program_day_id
         where sw.user_id = p_user_id and sw.status = 'pending'
           and sw.scheduled_for > v_today
         order by sw.scheduled_for limit 2
      ) x
    )
  );
end $$;

grant execute on function train_screen(uuid) to authenticated;
