-- =============================================================================
-- v2_0041 — materialise train_screen and resolve_level_change
--
-- No behaviour change. This is a readability migration.
--
-- v2_0036 and v2_0040 both altered train_screen by string-replacing its source
-- and re-creating it. Each patch is guarded and each is applied, but the effect
-- is that the function's current text exists nowhere in this repository: you
-- would have to read v2_0030 in full and then mentally apply two substitutions
-- to know what runs in production. That is a bad thing to leave behind in code
-- that decides how much weight someone is told to lift.
--
-- What follows is the live definition of both functions, dumped from the
-- database after v2_0040 and committed verbatim. From here they are edited as
-- ordinary source. The earlier patch migrations stay in place — they are the
-- record of WHY each change was made, which a full dump does not carry.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.train_screen(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_today    date := user_today(p_user_id);
  v_week0    date := date_trunc('week', v_today)::date;   -- Monday
  v_weekdays smallint[];
  v_sched    record;
  v_session  record;
  v_items    jsonb;
  v_prog_start date;
  v_exp      experience_level;
begin
  select training_weekdays, coalesce(experience, 'intermediate')
    into v_weekdays, v_exp
    from training_profiles where user_id = p_user_id and valid_to is null;
  v_exp := coalesce(v_exp, 'intermediate');

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
             e.demo_path, e.pattern::text as pattern
        from program_day_exercises pde
        join exercises e on e.id = pde.exercise_id
       where pde.program_day_id = v_sched.program_day_id
    ),
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
    sess_tops as (
      select exercise_id, performed_on, max(weight_kg) as top_kg
        from prev_raw group by exercise_id, performed_on
    ),
    stall as (
      -- Stalled = the last three sessions all topped out at the same weight.
      -- Fewer than three sessions is never a stall; it is just a short history.
      select exercise_id, (count(*) = 3 and min(top_kg) = max(top_kg)) as stalled
        from (select exercise_id, top_kg,
                     row_number() over (partition by exercise_id
                                            order by performed_on desc) as rn
                from sess_tops) t
       where rn <= 3
       group by exercise_id
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
      'sets_target',  case when exists (select 1 from programs pr where pr.user_id = p_user_id and pr.status = 'active' and pr.volume_ramp_until > v_today) then greatest(2, ceil(p.sets_target * 0.7)::int) else p.sets_target end,
      'rep_low',      p.rep_low,
      'rep_high',     p.rep_high,
      'rest_seconds', p.rest_seconds,
      'demo_path',    p.demo_path,
      'weight_step',  resolved_weight_step(p_user_id, p.exercise_id),
      'prefill_kg', coalesce(
        case
          when prev.exercise_id is null then p.target_weight_kg
          when prev.top_kg is null      then p.target_weight_kg
          -- Reactive deload (spec S7, advanced only): three sessions stuck at
          -- the same weight means the lift needs a step back, not more grit.
          -- Self-clearing: next session's top weight is lower, so the stall
          -- window no longer holds and normal progression resumes.
          when v_exp in ('beginner', 'advanced') and coalesce(st.stalled, false)
            then snap_to_loadable(p_user_id, round(prev.top_kg * 0.9, 1))
          -- Linear progression: a novice adapts session to session, so the bar
          -- goes up every time the last one was finished with something left,
          -- rather than only at the top of the rep range.
          when v_exp = 'beginner'
               and prev.effort is distinct from 'all'
               and coalesce(prev.last_rir, 1) >= 1
            then snap_to_loadable(p_user_id, prev.top_kg + greatest(
                   coalesce(resolved_weight_step(p_user_id, p.exercise_id), 2.5),
                   case when p.pattern = 'legs' then 5 else 2.5 end))
          -- Double progression: top of the range with a rep still in reserve.
          when prev.top_reps >= p.rep_high and coalesce(prev.last_rir, 0) >= 1
               and prev.effort is distinct from 'all'
            then snap_to_loadable(p_user_id,
                   prev.top_kg + coalesce(resolved_weight_step(p_user_id, p.exercise_id), 2.5))
          else prev.top_kg
        end, p.target_weight_kg, 0),
      'prefill_reps', coalesce(
        case
          when prev.exercise_id is null then p.rep_low
          when prev.unconfirmed         then p.rep_low
          -- A lighter bar restarts the range from the bottom.
          when v_exp in ('beginner', 'advanced') and coalesce(st.stalled, false) then p.rep_low
          -- Linear progression holds the reps and moves the weight.
          when v_exp = 'beginner'
               and prev.effort is distinct from 'all'
               and coalesce(prev.last_rir, 1) >= 1
            then coalesce(prev.top_reps, p.rep_low)
          when prev.effort = 'all' or coalesce(prev.last_rir, 0) = 0
            then coalesce(prev.top_reps, p.rep_low)
          when prev.top_reps >= p.rep_high and coalesce(prev.last_rir, 0) >= 1
            then p.rep_low
          when coalesce(prev.last_rir, 0) >= 2 or prev.effort = 'easy'
            then least(prev.top_reps + 2, p.rep_high)
          else least(coalesce(prev.top_reps, p.rep_low) + 1, p.rep_high)
        end, p.rep_high, 10),
      'coach_note', case
        when prev.exercise_id is null or prev.top_kg is null then null
        when v_exp in ('beginner', 'advanced') and coalesce(st.stalled, false)
          then p.name || ' has sat at ' || trim(trailing '.' from to_char(prev.top_kg, 'FM999990.9'))
               || ' kg for three sessions. Dropping it about 10% today so you can '
               || 'come back at it with something left in the tank.'
        when v_exp = 'beginner'
             and prev.effort is distinct from 'all'
             and coalesce(prev.last_rir, 1) >= 1
          then 'Up from ' || trim(trailing '.' from to_char(prev.top_kg, 'FM999990.9'))
               || ' kg — you finished last time with room to spare.'
        when prev.top_reps >= p.rep_high and coalesce(prev.last_rir, 0) >= 1
             and prev.effort is distinct from 'all'
          then 'You hit ' || prev.top_reps || ' reps with a rep in reserve — '
               || 'time to add weight.'
        else null
      end,
      'is_deload',    (v_exp in ('beginner', 'advanced') and coalesce(st.stalled, false)),
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
      left join stall st on st.exercise_id = p.exercise_id
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
      select jsonb_agg(day_obj order by (day_obj->>'date')) from (
        select jsonb_build_object(
          'date',    d::date,
          'dow',     extract(isodow from d)::int,
          'program_day_id', dsw.program_day_id,
          'label',   dpd.label,
          'planned', (dsw.program_day_id is not null
                     or extract(isodow from d)::int = any (coalesce(v_weekdays, '{}')))
                     and d::date >= coalesce(v_prog_start, d::date),
          'trained', exists (select 1 from workout_sessions ws2
                              where ws2.user_id = p_user_id
                                and ws2.performed_on = d::date
                                and ws2.status = 'completed'),
          'is_today', d::date = v_today,
          -- The day's lift list, for the in-place preview. Provisional loads
          -- (the plan target); the live adaptive prefill only applies to today.
          'exercises', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'name',             e.name,
                     'load_type',        e.load_type::text,
                     'sets_target',      pde.sets_target,
                     'rep_low',          pde.rep_low,
                     'rep_high',         pde.rep_high,
                     'target_weight_kg', pde.target_weight_kg
                   ) order by pde.ordinal)
              from program_day_exercises pde
              join exercises e on e.id = pde.exercise_id
             where pde.program_day_id = dsw.program_day_id), '[]'::jsonb)
        ) as day_obj
        from generate_series(v_week0, v_week0 + 6, interval '1 day') d
        left join lateral (
          select sw.program_day_id
            from scheduled_workouts sw
           where sw.user_id = p_user_id and sw.scheduled_for = d::date
           limit 1
        ) dsw on true
        left join program_days dpd on dpd.id = dsw.program_day_id
      ) w
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
end $function$

;

CREATE OR REPLACE FUNCTION public.resolve_level_change(p_proposal_id uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_p   record;
  v_to  experience_level;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  select * into v_p from coach_proposals
   where id = p_proposal_id and user_id = v_uid and kind = 'level_change';
  if not found then raise exception 'no such proposal'; end if;
  if v_p.status <> 'pending' then raise exception 'proposal already resolved'; end if;

  if not p_accept then
    update coach_proposals set status = 'rejected', resolved_at = now()
     where id = p_proposal_id;
    return;
  end if;

  v_to := (v_p.payload->>'to')::experience_level;

  -- §8.2: close the current row and insert a new one, using the versioning
  -- that has been sitting unused. The old row stops being current rather than
  -- being overwritten, so the lifter's journey is recoverable — which is what
  -- lets Progress eventually say "you became an intermediate lifter in March".
  update training_profiles set valid_to = now()
   where user_id = v_uid and valid_to is null;

  insert into training_profiles (
    user_id, goal, experience, environment, split_preference, days_per_week,
    target_weight_kg, target_date, goals, goal_is_coach_choice, target_direction,
    training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched, intake_confirmed)
  select user_id, goal, v_to, environment, split_preference, days_per_week,
         target_weight_kg, target_date, goals, goal_is_coach_choice, target_direction,
         training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched, intake_confirmed
    from training_profiles
   where user_id = v_uid and valid_to is not null
   order by valid_to desc limit 1;

  update coach_proposals set status = 'confirmed', resolved_at = now()
   where id = p_proposal_id;

  -- The level drives volume and exercise filtering, so the plan has to be
  -- rebuilt for the change to mean anything.
  perform bootstrap_user_program(v_uid);
  -- Promotion raises the weekly budget by roughly half again;
  -- give the lifter a week to meet it.
  update programs set volume_ramp_until = current_date + 7
   where user_id = v_uid and status = 'active';
end $function$

;
