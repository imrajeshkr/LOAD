-- =============================================================================
-- v2_0020 — swaps never relabel a day you already trained
--
-- _set_scheduled_day (used by swap_scheduled_days and swap_program_weekdays)
-- rewrites a date's session. It already refuses the past; extend it to also
-- refuse a date that carries a COMPLETED session — so a "just this week" swap
-- can't mislabel today after you've logged it, while an "every week" swap still
-- changes the pattern and all future (not-yet-trained) occurrences.
-- =============================================================================

create or replace function _set_scheduled_day(
  p_uid uuid, p_prog uuid, p_date date, p_pd uuid
)
returns void
language plpgsql security invoker as $$
begin
  if p_date < user_today(p_uid) then return; end if;   -- never touch the past
  -- Never relabel a day whose session is already logged — the record must keep
  -- matching what was actually trained.
  if exists (
    select 1 from workout_sessions ws
     where ws.user_id = p_uid and ws.performed_on = p_date and ws.status = 'completed'
  ) then
    return;
  end if;

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
