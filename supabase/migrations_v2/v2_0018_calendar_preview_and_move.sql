-- =============================================================================
-- v2_0018 — in-place day preview + rest-day moves (#4 calendar gaps)
--
--   * train_screen.week now carries each day's `exercises` (name, prescription,
--     provisional load) and `program_day_id`, so the Train tab can preview any
--     day in the visible week in-place, with no extra round-trip. Only the
--     `week` sub-object changes; today's adaptive `exercises`, `upcoming`, and
--     progress logic are verbatim from v2_0015.
--   * swap_scheduled_days now supports a MOVE — dropping a session onto a rest
--     day (one side has no scheduled row). The origin becomes rest; the target
--     takes the session. Swaps (both sides training) behave as before. Works
--     for both 'week' and 'forever' scope.
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
end $$;

grant execute on function train_screen(uuid) to authenticated;

-- ── swap OR move ─────────────────────────────────────────────────────────────
-- Rearrange the split by exchanging two days. Forward-only.
--   Both days training → swap the two sessions.
--   One day rest       → move: the training session lands on the rest day and
--                        its origin becomes rest.
--   scope 'week'    — just those two dated rows.
--   scope 'forever' — the weekday pattern too, then rewrite all future rows on
--                     the affected weekdays. Undo = call again with args swapped.
create or replace function swap_scheduled_days(
  p_from  date,
  p_to    date,
  p_scope text
)
returns void
language plpgsql security invoker as $$
declare
  v_uid     uuid := auth.uid();
  v_prog    uuid;
  v_today   date;
  v_from_pd uuid;
  v_to_pd   uuid;
  v_wf      smallint;
  v_wt      smallint;
  v_max     date;
  v_d       date;
  v_wd      smallint;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  v_today := user_today(v_uid);
  if p_from < v_today or p_to < v_today then
    raise exception 'can only rearrange today or later';
  end if;
  if p_from = p_to then return; end if;

  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then raise exception 'no active program'; end if;

  select program_day_id into v_from_pd
    from scheduled_workouts where user_id = v_uid and scheduled_for = p_from limit 1;
  select program_day_id into v_to_pd
    from scheduled_workouts where user_id = v_uid and scheduled_for = p_to limit 1;
  -- At least one side must hold a session; two rest days have nothing to do.
  if v_from_pd is null and v_to_pd is null then
    raise exception 'nothing to move — both days are rest days';
  end if;

  if p_scope = 'week' then
    perform _set_scheduled_day(v_uid, v_prog, p_from, v_to_pd);
    perform _set_scheduled_day(v_uid, v_prog, p_to,   v_from_pd);

  elsif p_scope = 'forever' then
    v_wf := extract(isodow from p_from)::smallint;
    v_wt := extract(isodow from p_to)::smallint;

    perform _set_weekday_slot(v_uid, v_prog, v_wf, v_to_pd);
    perform _set_weekday_slot(v_uid, v_prog, v_wt, v_from_pd);

    -- Rewrite every future row on those two weekdays to match the new pattern.
    select max(scheduled_for) into v_max
      from scheduled_workouts where user_id = v_uid;
    if v_max is not null then
      for v_d in
        select gs::date from generate_series(v_today, v_max, interval '1 day') gs
      loop
        v_wd := extract(isodow from v_d)::smallint;
        if v_wd = v_wf then
          perform _set_scheduled_day(v_uid, v_prog, v_d, v_to_pd);
        elsif v_wd = v_wt then
          perform _set_scheduled_day(v_uid, v_prog, v_d, v_from_pd);
        end if;
      end loop;
    end if;
  else
    raise exception 'bad scope %', p_scope;
  end if;
end $$;

grant execute on function swap_scheduled_days(date, date, text) to authenticated;

-- Set one dated row to a program day, or clear it (null = becomes rest).
-- Update-in-place when a row exists (keeps the row id, so any session FK
-- survives), insert when the day was rest, delete when vacating. One path for
-- both swap and move.
create or replace function _set_scheduled_day(
  p_uid uuid, p_prog uuid, p_date date, p_pd uuid
)
returns void
language plpgsql security invoker as $$
begin
  if p_date < user_today(p_uid) then return; end if;   -- never touch the past
  if p_pd is null then
    delete from scheduled_workouts
     where user_id = p_uid and scheduled_for = p_date;
  else
    update scheduled_workouts
       set program_day_id = p_pd, program_id = p_prog
     where user_id = p_uid and scheduled_for = p_date;
    if not found then
      insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
      values (p_uid, p_prog, p_pd, p_date);
    end if;
  end if;
end $$;

-- Set one weekday's pattern slot, or clear it (null = that weekday becomes rest).
create or replace function _set_weekday_slot(
  p_uid uuid, p_prog uuid, p_weekday smallint, p_pd uuid
)
returns void
language plpgsql security invoker as $$
begin
  if p_pd is null then
    delete from program_weekday_slots
     where program_id = p_prog and weekday = p_weekday;
  else
    insert into program_weekday_slots (program_id, user_id, weekday, program_day_id)
    values (p_prog, p_uid, p_weekday, p_pd)
    on conflict (program_id, weekday)
      do update set program_day_id = excluded.program_day_id;
  end if;
end $$;
