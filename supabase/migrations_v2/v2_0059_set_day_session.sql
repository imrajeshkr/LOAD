-- =============================================================================
-- v2_0059 — set one day's session directly
--
-- The calendar could only ever SWAP two days: to make Sunday a Legs day you
-- had to find the Legs day and drag it. That is a puzzle, not a control, and
-- it cannot express "this Sunday is a leg day" at all unless some other day
-- gives one up.
--
-- set_day_session assigns a session to a date, or clears it. It changes that
-- one day and nothing else: picking Legs for Sunday leaves Friday's Legs
-- exactly where it is, and picking Rest drops that day's session rather than
-- relocating it. Weekly volume is then the lifter's to shape — a deliberate
-- trade, chosen over silently rearranging days they did not touch.
--
-- Both guards in _set_scheduled_day still apply: the past is never edited, and
-- a day whose session is already logged is never relabelled, so the record
-- keeps matching what was actually trained.
-- =============================================================================

create or replace function set_day_session(
  p_date           date,
  p_program_day_id uuid    -- null = make it a rest day
)
returns void
language plpgsql security invoker as $$
declare
  v_uid  uuid := auth.uid();
  v_prog uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_date < user_today(v_uid) then
    raise exception 'can only change today or later';
  end if;

  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then raise exception 'no active program'; end if;

  -- A program day from somebody else's program would schedule a session this
  -- lifter cannot see. Verify before trusting the argument.
  if p_program_day_id is not null and not exists (
    select 1 from program_days pd
     where pd.id = p_program_day_id and pd.program_id = v_prog
  ) then
    raise exception 'that session is not part of your program';
  end if;

  perform _set_scheduled_day(v_uid, v_prog, p_date, p_program_day_id);
end $$;

grant execute on function set_day_session(date, uuid) to authenticated;

-- The picker's options: every session this program can put on a day.
-- Ordered by the rotation so the list reads Push, Pull, Legs rather than
-- alphabetically.
create or replace function my_program_days()
returns table (id uuid, ordinal int, label text)
language sql security invoker stable as $$
  select pd.id, pd.ordinal, pd.label
    from program_days pd
    join programs p on p.id = pd.program_id
   where p.user_id = auth.uid() and p.status = 'active'
   order by pd.ordinal;
$$;

grant execute on function my_program_days() to authenticated;
