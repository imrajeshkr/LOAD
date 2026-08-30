-- =============================================================================
-- v2_0060 — make a day change recurring
--
-- set_day_session (v2_0059) changes one date, which is what "I can't train
-- this Friday" means. The other intent — "Sunday is my leg day now" — is
-- rarer but real, and it was previously unreachable except by editing the
-- split in the profile.
--
-- This promotes a date's session to that weekday's standing pattern and
-- rewrites every future row on that weekday to match, exactly as
-- swap_scheduled_days already does under scope 'forever'. It is offered as a
-- follow-up to the single-day change rather than a choice made up front:
-- quietly rewriting a whole block because someone rescheduled one Friday
-- around a wedding is the kind of change nobody notices for a month.
-- =============================================================================

create or replace function set_weekday_session(
  p_weekday        smallint,   -- 1=Mon .. 7=Sun (ISO)
  p_program_day_id uuid        -- null = that weekday becomes rest
)
returns void
language plpgsql security invoker as $$
declare
  v_uid   uuid := auth.uid();
  v_prog  uuid;
  v_today date;
  v_max   date;
  v_d     date;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_weekday < 1 or p_weekday > 7 then
    raise exception 'weekday must be 1..7';
  end if;

  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then raise exception 'no active program'; end if;

  if p_program_day_id is not null and not exists (
    select 1 from program_days pd
     where pd.id = p_program_day_id and pd.program_id = v_prog
  ) then
    raise exception 'that session is not part of your program';
  end if;

  perform _set_weekday_slot(v_uid, v_prog, p_weekday, p_program_day_id);

  -- Bring the already-materialised future into line with the new pattern.
  -- _set_scheduled_day skips the past and refuses to relabel a logged day, so
  -- history is safe without a second guard here.
  v_today := user_today(v_uid);
  select max(scheduled_for) into v_max
    from scheduled_workouts where user_id = v_uid;
  if v_max is null then return; end if;

  for v_d in
    select gs::date from generate_series(v_today, v_max, interval '1 day') gs
  loop
    if extract(isodow from v_d)::smallint = p_weekday then
      perform _set_scheduled_day(v_uid, v_prog, v_d, p_program_day_id);
    end if;
  end loop;
end $$;

grant execute on function set_weekday_session(smallint, uuid) to authenticated;
