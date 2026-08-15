-- =============================================================================
-- v2_0012 — fix session_summary(): nested-aggregate error in the 'exercises'
-- block. The outer jsonb_agg wrapped sum()/jsonb_agg() inline over a GROUP BY,
-- which Postgres rejects (42803: aggregate function calls cannot be nested).
-- Compute the per-exercise aggregates in a subquery first, then jsonb_agg the
-- rows — the same shape the 'trend' and 'muscles' blocks already use.
-- Everything else is unchanged from v2_0010.
-- =============================================================================

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
    'last_same', last_same_day_totals(p_user_id, v_s.title, v_s.performed_on),
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
    -- FIXED: per-exercise aggregates computed in the subquery, then agg'd.
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
