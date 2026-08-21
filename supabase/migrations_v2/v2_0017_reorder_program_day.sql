-- =============================================================================
-- v2_0017 — reorder today's program day (free-order "Make it the plan", #7)
--
-- When a lifter reorders the session board and chooses "Make it the plan", the
-- new order should stick for future sessions of that day. Rewrite
-- program_day_exercises.ordinal for today's program day to the given order.
--
-- Definer + self-derived target: the program day is looked up from the CALLER's
-- own scheduled_workouts for today, so it can only ever touch their own plan.
-- =============================================================================

create or replace function reorder_my_day(p_exercise_ids uuid[])
returns void
language plpgsql
security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_pd  uuid;
  v_i   int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select sw.program_day_id into v_pd
    from scheduled_workouts sw
   where sw.user_id = v_uid and sw.scheduled_for = user_today(v_uid)
   limit 1;
  if v_pd is null then return; end if;

  -- Two passes to slide past the unique (program_day_id, ordinal) constraint:
  -- park everything high, then set the final positions.
  update program_day_exercises set ordinal = ordinal + 1000
   where program_day_id = v_pd;

  for v_i in 1 .. coalesce(array_length(p_exercise_ids, 1), 0) loop
    update program_day_exercises
       set ordinal = v_i
     where program_day_id = v_pd and exercise_id = p_exercise_ids[v_i];
  end loop;
end $$;

revoke all on function reorder_my_day(uuid[]) from public;
grant execute on function reorder_my_day(uuid[]) to authenticated;
