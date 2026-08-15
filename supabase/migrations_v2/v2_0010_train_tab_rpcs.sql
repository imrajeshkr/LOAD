-- =============================================================================
-- LOAD v2 — Train tab RPCs
--
--   snap_to_loadable()         F3 — the plate-inventory promise, enforced
--   resolved_weight_step()     F4 — per-lift stepper increment
--   train_screen()             replaces today_plan(): plan + streak + preview
--   session_summary()          the after-state: totals, delta, trend, PBs
--   progression_suggestions()  "next time these go up", with reasons
--
-- train_screen deliberately does NOT include the morning note: coach_messages
-- is a plain RLS-scoped table the client reads directly, and coupling the two
-- would mean a note delay blocks the whole tab.
-- =============================================================================

-- ── F3: never prescribe a weight the user cannot build ──────────────────
-- With unlimited count per owned size, achievable per-side sums are the
-- multiples of the GCD of the sizes; total increments are 2 x that. Snaps DOWN
-- (a lighter bar than asked beats an impossible one), floored at the bar.
create or replace function snap_to_loadable(p_user_id uuid, p_kg numeric)
returns numeric
language plpgsql stable security invoker as $$
declare
  v_bar   numeric;
  v_sizes numeric[];
  v_g     int := 0;
  v_s     numeric;
  v_inc   numeric;
begin
  select bar_weight_kg, plate_sizes_kg into v_bar, v_sizes
    from training_profiles
   where user_id = p_user_id and valid_to is null;

  v_bar := coalesce(v_bar, 20);
  if p_kg is null or p_kg <= v_bar then return v_bar; end if;
  if v_sizes is null or cardinality(v_sizes) = 0 then return v_bar; end if;

  -- GCD in centi-kg so 1.25 and 2.5 stay exact.
  foreach v_s in array v_sizes loop
    v_g := gcd(v_g, (v_s * 100)::int);
  end loop;
  if v_g = 0 then return v_bar; end if;

  v_inc := 2 * v_g / 100.0;
  return v_bar + floor((p_kg - v_bar) / v_inc) * v_inc;
end $$;

grant execute on function snap_to_loadable(uuid, numeric) to authenticated;

-- ── F4: the stepper increment for a lift ────────────────────────────────
-- Fixed step where the catalog sets one (dumbbell 2, machine 2.5); barbell
-- lifts derive 2 x the smallest owned plate; bodyweight lifts return NULL.
create or replace function resolved_weight_step(p_user_id uuid, p_exercise_id uuid)
returns numeric
language sql stable security invoker as $$
  select case
    when e.load_type in ('bodyweight_reps') then null
    when e.weight_step_kg is not null then e.weight_step_kg
    when exists (select 1 from exercise_equipment ee
                   join equipment q on q.id = ee.equipment_id
                  where ee.exercise_id = e.id and q.slug = 'barbell')
      then coalesce(2 * (select min(s) from unnest(
             (select tp.plate_sizes_kg from training_profiles tp
               where tp.user_id = p_user_id and tp.valid_to is null)) s), 2.5)
    else 2.5
  end
  from exercises e where e.id = p_exercise_id;
$$;

grant execute on function resolved_weight_step(uuid, uuid) to authenticated;

-- ── the Train tab, before-state ─────────────────────────────────────────
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

  -- A fresh signup mid-week has no history before the account existed — days
  -- before it started are "nothing scheduled yet", not missed. Anchored on
  -- the account's own created_at, NOT the active program's starts_on: that
  -- resets every time the plan is regenerated (Profile "Rewrite my week"),
  -- which would wrongly re-hide weekdays that were already normal training
  -- days before that regeneration.
  select created_at::date into v_prog_start
    from profiles where id = p_user_id;

  -- Today's slot, if any.
  select sw.id, sw.program_day_id, pd.label into v_sched
    from scheduled_workouts sw
    join program_days pd on pd.id = sw.program_day_id
   where sw.user_id = p_user_id and sw.scheduled_for = v_today
   limit 1;

  -- Today's session row (any status), for resuming or the after-state.
  select ws.id, ws.status::text, ws.started_at into v_session
    from workout_sessions ws
   where ws.user_id = p_user_id and ws.performed_on = v_today
   order by ws.started_at desc limit 1;

  -- Prescription + prefill for today's day (same shape today_plan used, plus
  -- weight_step and the snapped target).
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
    prev as (
      select exercise_id, sets from (
        select se.exercise_id,
               jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps)
                         order by ss.set_number) as sets,
               row_number() over (partition by se.exercise_id
                                  order by ws.performed_on desc) as rn
          from session_sets ss
          join session_exercises se on se.id = ss.session_exercise_id
          join workout_sessions  ws on ws.id = se.session_id
         where se.user_id = p_user_id and ws.performed_on < v_today
           and ws.status = 'completed' and ss.is_completed and ss.kind = 'working'
         group by se.exercise_id, ws.performed_on
      ) r where rn = 1
    ),
    -- Sets already logged in *today's* session (in_progress or completed),
    -- so a lift left mid-way shows real progress on the plan chip and the
    -- card can offer "Continue" instead of "Start" the moment anything exists.
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
      -- `->>` (not `->`) so a bodyweight set's stored JSON null weight comes
      -- back as a real SQL NULL that coalesce can fall through; casting a jsonb
      -- null straight to numeric throws 22023 and takes the whole RPC down.
      'prefill_kg',   coalesce((prev.sets -> -1 ->> 0)::numeric, p.target_weight_kg, 0),
      'prefill_reps', coalesce(p.rep_high, 10),
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
    -- 7-day streak strip, Monday-anchored: planned from the schedule, trained
    -- from completed sessions.
    'week', (
      select jsonb_agg(jsonb_build_object(
        'date',    d::date,
        'dow',     extract(isodow from d)::int,
        -- The real scheduled label, so the calendar can tag each day (PUSH /
        -- PULL / LEGS) rather than just a plain/rest dot.
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
    -- Tomorrow and the one after — feeds both "Tomorrow" and the rest-day
    -- "Then · Fri · Leg day" row. Each carries its own lifts + provisional
    -- loads so the Tomorrow sheet needs no second round trip.
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

-- ── the after-state ─────────────────────────────────────────────────────
create or replace function session_summary(p_user_id uuid, p_session_id uuid)
returns jsonb
language plpgsql stable security invoker as $$
declare
  v_s record;
begin
  select ws.id, ws.title, ws.performed_on, ws.started_at, ws.completed_at,
         ws.situation::text as situation
    into v_s
    from workout_sessions ws
   where ws.id = p_session_id and ws.user_id = p_user_id;
  if v_s.id is null then return null; end if;

  return jsonb_build_object(
    'label',        v_s.title,
    'performed_on', v_s.performed_on,
    'situation',    v_s.situation,
    'duration_min', case when v_s.completed_at is null then null
                         else round(extract(epoch from (v_s.completed_at - v_s.started_at)) / 60) end,
    'totals', (
      select jsonb_build_object(
        'set_count',  count(*),
        'volume_kg',  coalesce(sum(ss.volume_kg), 0),
        'exercise_count', count(distinct se.exercise_id))
        from session_sets ss
        join session_exercises se on se.id = ss.session_exercise_id
       where se.session_id = v_s.id and ss.is_completed and ss.kind = 'working'
    ),
    -- "+155 vs last push": same label-matched comparison v1 already solved.
    'last_same', last_same_day_totals(p_user_id, v_s.title, v_s.performed_on),
    -- Six-session trend, this label, oldest first, including today.
    'trend', (
      select coalesce(jsonb_agg(t order by (t->>'on')), '[]'::jsonb) from (
        select jsonb_build_object('on', ws.performed_on,
                 'volume_kg', coalesce(sum(ss.volume_kg), 0)) as t
          from workout_sessions ws
          join session_exercises se on se.session_id = ws.id
          join session_sets ss on ss.session_exercise_id = se.id
         where ws.user_id = p_user_id and ws.status = 'completed'
           and ss.is_completed and ss.kind = 'working'
           and ws.performed_on <= v_s.performed_on
           and (ws.title = v_s.title
                or exists (select 1 from program_days d
                            where d.id = ws.program_day_id and d.label = v_s.title))
         group by ws.performed_on
         order by ws.performed_on desc limit 6
      ) x
    ),
    -- Per-exercise: volume bars ("where the work went") + set recap rows.
    -- Every aggregate (sum/count/max/jsonb_agg) has to be computed in its own
    -- subquery first: Postgres's "aggregate function calls cannot be nested"
    -- fires the instant ANY aggregate call sits syntactically inside another
    -- aggregate's argument list — including as a sibling passed through
    -- jsonb_build_object, not just literal agg(agg(...)) — so the outer
    -- jsonb_agg here may only ever reference plain columns, never call one.
    'exercises', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name', x.name, 'load_type', x.load_type, 'ordinal', x.ordinal,
               'volume_kg', x.volume_kg, 'total_reps', x.total_reps,
               'set_count', x.set_count, 'top_kg', x.top_kg, 'sets', x.sets
             ) order by x.ordinal), '[]'::jsonb)
      from (
        select se.ordinal, e.name, e.load_type::text as load_type,
               coalesce(sum(ss.volume_kg), 0) as volume_kg,
               coalesce(sum(ss.reps), 0)      as total_reps,
               count(ss.id)                    as set_count,
               max(ss.weight_kg)               as top_kg,
               jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps)
                         order by ss.set_number) as sets
          from session_exercises se
          join exercises e on e.id = se.exercise_id
          join session_sets ss on ss.session_exercise_id = se.id
         where se.session_id = v_s.id and ss.is_completed and ss.kind = 'working'
         group by se.id, e.id, se.ordinal, e.name, e.load_type
      ) x
    ),
    -- Muscle chips: this session's working sets by display group.
    'muscles', (
      select coalesce(jsonb_agg(jsonb_build_object('group', g, 'sets', n)
                                order by n desc), '[]'::jsonb) from (
        select m.display_group as g, count(distinct ss.id) as n
          from session_sets ss
          join session_exercises se on se.id = ss.session_exercise_id
          join exercise_muscles em on em.exercise_id = se.exercise_id
                                   and em.role = 'primary'
          join muscles m on m.id = em.muscle_id
         where se.session_id = v_s.id and ss.is_completed
           and ss.kind = 'working' and m.display_group is not null
         group by m.display_group
      ) x
    ),
    -- PBs: a set today whose reps beat every earlier set of that exercise at
    -- the same weight or heavier. Requires prior history at >= weight — a
    -- first-ever lift is a baseline, not a PB (the design compares, always).
    'pbs', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name', e.name, 'kg', ss.weight_kg, 'reps', ss.reps,
               'prev_reps', prev.best) order by ss.weight_kg desc), '[]'::jsonb)
        from session_sets ss
        join session_exercises se on se.id = ss.session_exercise_id
        join exercises e on e.id = se.exercise_id
        cross join lateral (
          select max(ss2.reps) as best
            from session_sets ss2
            join session_exercises se2 on se2.id = ss2.session_exercise_id
            join workout_sessions ws2 on ws2.id = se2.session_id
           where se2.user_id = p_user_id
             and se2.exercise_id = se.exercise_id
             and ws2.performed_on < v_s.performed_on
             and ws2.status = 'completed'
             and ss2.is_completed and ss2.kind = 'working'
             and ss2.weight_kg >= ss.weight_kg
        ) prev
       where se.session_id = v_s.id
         and ss.is_completed and ss.kind = 'working'
         and ss.weight_kg is not null
         and prev.best is not null and ss.reps > prev.best
    )
  );
end $$;

grant execute on function session_summary(uuid, uuid) to authenticated;

-- ── "next time these go up", with the reason shown ──────────────────────
-- Reads the last completed session per exercise in the active program.
-- Reasons (client copy keys off these):
--   unconfirmed    → hold: last time was auto-accepted defaults, not measured
--   grind          → hold: effort answer "that was everything" / RIR 0
--   reps_in_reserve→ up:   two or more reps left on the final set
--   top_of_range   → up:   finished the top of the prescribed range
--   building_reps  → hold: still working through the range
--   no_history     → nothing to base a suggestion on
create or replace function progression_suggestions(p_user_id uuid)
returns table (
  exercise_id  uuid,
  name         text,
  current_kg   numeric,
  suggested_kg numeric,
  delta_kg     numeric,
  reason       text
)
language sql stable security invoker as $$
  with program_lifts as (
    select distinct pde.exercise_id, pde.rep_high
      from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join programs p on p.id = pd.program_id
     where p.user_id = p_user_id and p.status = 'active'
  ),
  last_session_sets as (
    select se.id as se_id, se.exercise_id, se.effort::text as effort,
           se.is_unconfirmed, ws.performed_on,
           ss.weight_kg, ss.reps, ss.rir, ss.set_number,
           max(ss.weight_kg) over (partition by se.id) as sess_top
      from session_sets ss
      join session_exercises se on se.id = ss.session_exercise_id
      join workout_sessions ws on ws.id = se.session_id
     where se.user_id = p_user_id and ws.status = 'completed'
       and ss.is_completed and ss.kind = 'working' and ss.weight_kg is not null
  ),
  last_session as (
    select * from (
      select exercise_id, effort, is_unconfirmed, performed_on,
             max(weight_kg) as top_kg,
             (array_agg(rir order by set_number desc))[1] as last_rir,
             max(reps) filter (where weight_kg = sess_top) as top_reps,
             row_number() over (partition by exercise_id
                                order by performed_on desc) as rn
        from last_session_sets
       group by se_id, exercise_id, effort, is_unconfirmed, performed_on, sess_top
    ) r where rn = 1
  )
  select pl.exercise_id,
         e.name,
         ls.top_kg,
         case when verdict.up
              then snap_to_loadable(p_user_id,
                     ls.top_kg + coalesce(resolved_weight_step(p_user_id, pl.exercise_id), 2.5))
              else ls.top_kg end,
         case when verdict.up
              then snap_to_loadable(p_user_id,
                     ls.top_kg + coalesce(resolved_weight_step(p_user_id, pl.exercise_id), 2.5))
                   - ls.top_kg
              else 0 end,
         verdict.reason
    from program_lifts pl
    join exercises e on e.id = pl.exercise_id
    left join last_session ls on ls.exercise_id = pl.exercise_id
    cross join lateral (
      select
        case
          when ls.exercise_id is null                          then false
          when ls.is_unconfirmed                               then false
          when ls.effort = 'all' or ls.last_rir = 0            then false
          when coalesce(ls.last_rir, -1) >= 2
            or ls.effort = 'easy'                              then true
          when ls.top_reps >= pl.rep_high                      then true
          else false
        end as up,
        case
          when ls.exercise_id is null                          then 'no_history'
          when ls.is_unconfirmed                               then 'unconfirmed'
          when ls.effort = 'all' or ls.last_rir = 0            then 'grind'
          when coalesce(ls.last_rir, -1) >= 2
            or ls.effort = 'easy'                              then 'reps_in_reserve'
          when ls.top_reps >= pl.rep_high                      then 'top_of_range'
          else 'building_reps'
        end as reason
    ) verdict;
$$;

grant execute on function progression_suggestions(uuid) to authenticated;
