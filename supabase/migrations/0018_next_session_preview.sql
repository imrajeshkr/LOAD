-- =============================================================================
-- LOAD — "Up next" preview for the post-session Today card
--
-- Mirrors today_plan()'s plan-building query, pointed at the next scheduled
-- day after today instead of today's own — so the completed-session card can
-- show what's coming without the client faking it from static data.
-- =============================================================================

create or replace function next_session_preview(p_user_id uuid)
returns jsonb
language plpgsql stable security invoker as $$
declare
  v_today   date := user_today(p_user_id);
  v_program uuid;
  v_day     uuid;
  v_label   text;
  v_when    date;
  v_items   jsonb;
begin
  select id into v_program
    from programs where user_id = p_user_id and status = 'active';

  if v_program is null then
    return jsonb_build_object('has_next', false);
  end if;

  select program_day_id, scheduled_for into v_day, v_when
    from scheduled_workouts
   where user_id = p_user_id and program_id = v_program
     and status = 'pending' and scheduled_for > v_today
   order by scheduled_for limit 1;

  if v_day is null then
    return jsonb_build_object('has_next', false);
  end if;

  select label into v_label from program_days where id = v_day;

  select jsonb_agg(
    jsonb_build_object(
      'exercise_id',  e.id,
      'name',         e.name,
      'load_type',    e.load_type::text,
      'sets_target',  pde.sets_target,
      'rep_low',      pde.rep_low,
      'rep_high',     pde.rep_high,
      'rest_seconds', pde.rest_seconds,
      'demo_path',    e.demo_path,
      'joints',       coalesce((select jsonb_agg(j.slug)
                                  from exercise_joints ej join joints j on j.id = ej.joint_id
                                 where ej.exercise_id = e.id), '[]'::jsonb),
      'cues',         coalesce((select jsonb_agg(c.body order by c.position)
                                  from exercise_cues c where c.exercise_id = e.id), '[]'::jsonb)
    ) order by pde.ordinal)
    into v_items
    from program_day_exercises pde
    join exercises e on e.id = pde.exercise_id
   where pde.program_day_id = v_day;

  return jsonb_build_object(
    'has_next',      true,
    'label',         v_label,
    'scheduled_for', v_when,
    'exercises',     coalesce(v_items, '[]'::jsonb)
  );
end $$;

grant execute on function next_session_preview(uuid) to authenticated;
