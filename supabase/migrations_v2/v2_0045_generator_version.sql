-- =============================================================================
-- v2_0045 — migrate people off the old generator (§13.1)
--
-- Everything built across plans 03-07 only reaches a lifter when their program
-- is REBUILT. Nothing rebuilds a working plan, so every existing user is still
-- running whatever the generator produced the day they signed up. On the live
-- database that is all seven active programs:
--
--   * 3 program_days each — including users training 6 and 7 days a week, who
--     are cycling three sessions instead of getting six
--   * no core pattern, so none of them trains abs at all
--   * built before goals affected reps, rest or volume
--   * ends_on null, so block rollover never fires and they never get out
--
-- §13.1 called for exactly this and named the missing piece: "a
-- `generator_version` column on `programs` so we can tell who is on what and
-- migrate in waves rather than one big-bang."
--
-- FORCE OR OFFER. §13.1 distinguishes plans that are actively broken (force,
-- announce after) from plans that are merely older (offer at a boundary). Every
-- surviving plan is in the first group: a 7-day lifter given 3 sessions, and
-- nobody training abs, is not a stylistic difference. So this forces — and per
-- the section's own principle, "silently leaving a broken plan in place" is the
-- worse trust violation.
--
-- NEVER MID-WEEK. The rebuild waits until the lifter has no completed session
-- in the current week. Rewriting a week someone has already started is the
-- thing §13.1 exists to prevent. Using "no session logged this week" rather
-- than "is it Monday" avoids stranding someone who only ever opens the app on
-- a Wednesday.
-- =============================================================================

alter table programs
  add column if not exists generator_version int not null default 3;

comment on column programs.generator_version is
  'Which generator produced this program. Bump CURRENT_GENERATOR in '
  'roll_block_if_due when the generator changes in a way existing plans should '
  'be migrated onto; anything older is rebuilt at the lifter''s next week '
  'boundary.';

-- Everything that exists right now predates the volume-driven generator.
update programs set generator_version = 1 where created_at < now();


create or replace function roll_block_if_due(p_user_id uuid)
returns text
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  -- Bump this when the generator changes enough that existing plans should be
  -- migrated. v2_0029 (volume-driven) is 3.
  c_generator constant int := 3;
  v_prog    record;
  v_thread  uuid;
  v_layoff  int;
  v_reason  text;
  v_body    text;
  v_weeks   int;
  v_added   text;
begin
  select id, ends_on, starts_on, generator_version into v_prog
    from programs where user_id = p_user_id and status = 'active' limit 1;
  if not found then return null; end if;

  if is_training_paused(p_user_id) then return null; end if;

  v_layoff := layoff_days(p_user_id);

  if exists (select 1 from training_pauses
              where user_id = p_user_id and ended_on is not null
                and ended_on >= user_today(p_user_id) - 7)
     and v_layoff >= 14 then
    v_reason := 'returning_declared';
  elsif v_layoff >= 21 then
    v_reason := 'returning_silent';
  elsif v_prog.ends_on is not null and v_prog.ends_on <= user_today(p_user_id) then
    v_reason := 'block_end';
  elsif coalesce(v_prog.generator_version, 1) < c_generator
        and not exists (
          select 1 from workout_sessions ws
           where ws.user_id = p_user_id and ws.status = 'completed'
             and ws.performed_on >= date_trunc('week', user_today(p_user_id))::date)
  then
    v_reason := 'generator_upgrade';
  else
    return null;
  end if;

  perform bootstrap_user_program(p_user_id);

  update programs set volume_ramp_until = user_today(p_user_id) + 7
   where user_id = p_user_id and status = 'active';

  v_weeks := greatest(1, round((coalesce(v_prog.ends_on, user_today(p_user_id))
                                - v_prog.starts_on) / 7.0)::int);

  select coalesce(' — this time ' || array_to_string(d.added[1:2], ' and '), '')
    into v_added from program_diff(p_user_id) d where cardinality(d.added) > 0;
  v_added := coalesce(v_added, '');

  v_body := case v_reason
    when 'block_end' then
      'That is ' || v_weeks || ' weeks done on this plan. The next one is '
      || 'ready — same main lifts, since those are working, with a couple of '
      || 'new accessories' || v_added || '. This first week is deliberately '
      || 'lighter so you start it fresh rather than carrying the last six '
      || 'weeks into it.'
    when 'returning_declared' then
      'Welcome back. Picking up where you left off — your loads are as you '
      || 'left them, and this first week is lighter so the first session back '
      || 'is not the hardest one you have had.'
    when 'returning_silent' then
      'Good to see you. It has been ' || (v_layoff / 7) || ' weeks, so I have '
      || 'kept your lifts and made this week lighter to ease back in. If you '
      || 'have been training elsewhere and that feels too easy, just put the '
      || 'weight up — I will follow you.'
    else
      -- §13.1: tell them after, and say what they were missing rather than
      -- announcing an upgrade. "We improved our algorithm" is not news to a
      -- lifter; "your week now covers everything" is.
      'I have rebuilt your week. Your training days now each get their own '
      || 'session instead of repeating a few, every muscle gets work across '
      || 'the week — including the ones the old plan kept skipping — and your '
      || 'sets and rest now follow the goal you picked. Same main lifts'
      || v_added || '. This week is lighter while you settle into it.'
  end;

  select id into v_thread from coach_threads
   where user_id = p_user_id order by last_message_at desc nulls last limit 1;
  if v_thread is null then
    insert into coach_threads (user_id, title) values (p_user_id, 'Coach')
    returning id into v_thread;
  end if;

  insert into coach_messages (user_id, thread_id, role, content, category, needs_attention)
  values (p_user_id, v_thread, 'assistant', v_body, 'plan_updated', true);
  update coach_threads set last_message_at = now() where id = v_thread;

  return v_reason;
end $$;
