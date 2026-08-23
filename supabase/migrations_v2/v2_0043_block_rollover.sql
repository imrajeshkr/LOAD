-- =============================================================================
-- v2_0043 — roll the block when it ends, and ease people back in (§8.4, §13.8)
--
-- v2_0042 gave programs an end date. This is what happens when that date
-- arrives, and what happens when someone comes back after time away — the two
-- are the same shape of problem: the plan needs rebuilding and the first week
-- needs to be lighter than the target.
--
-- Neither is a proposal. A block boundary is a planned part of the programme
-- the lifter already agreed to, and coming back from a layoff is not a choice
-- they are making — so both just happen, and both are announced. That is the
-- opposite of §8.2's rule for LEVEL changes, which alter the deal and
-- therefore need consent.
--
-- Per §13.5 the word "deload" appears nowhere the user can see.
-- =============================================================================

-- ── How long has this person been away? ─────────────────────────────────────
-- §13.8: a declared pause is information; silence is not. A pause tells us why
-- and how long, so the threshold is the pause itself. Silence tells us nothing,
-- so the threshold is a cautious 3 weeks — meaningful detraining starts around
-- 3-4 weeks and, absent information, the careful default is better.
create or replace function layoff_days(p_user_id uuid)
returns int language sql stable as $$
  select greatest(0, coalesce(
    user_today(p_user_id) - (
      select max(ws.performed_on) from workout_sessions ws
       where ws.user_id = p_user_id and ws.status = 'completed'), 0));
$$;


-- ── The rollover ────────────────────────────────────────────────────────────
-- Safe to call as often as you like: it does nothing unless something is due.
create or replace function roll_block_if_due(p_user_id uuid)
returns text
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_prog    record;
  v_thread  uuid;
  v_layoff  int;
  v_paused  boolean;
  v_reason  text;
  v_body    text;
  v_weeks   int;
begin
  select id, ends_on, starts_on into v_prog
    from programs where user_id = p_user_id and status = 'active' limit 1;
  if not found then return null; end if;

  v_paused := is_training_paused(p_user_id);
  if v_paused then return null; end if;   -- nothing rolls while paused

  v_layoff := layoff_days(p_user_id);

  -- A declared pause that has ended is a return we were told about, so no
  -- question is asked. That silence is the reward for using the feature.
  if exists (select 1 from training_pauses
              where user_id = p_user_id and ended_on is not null
                and ended_on >= user_today(p_user_id) - 7)
     and v_layoff >= 14 then
    v_reason := 'returning_declared';
  elsif v_layoff >= 21 then
    v_reason := 'returning_silent';
  elsif v_prog.ends_on is not null and v_prog.ends_on <= user_today(p_user_id) then
    v_reason := 'block_end';
  else
    return null;
  end if;

  perform bootstrap_user_program(p_user_id);

  -- A lighter opening week, whichever path got us here: after a block because
  -- that is the planned reset, after a layoff because the body has detrained.
  update programs set volume_ramp_until = user_today(p_user_id) + 7
   where user_id = p_user_id and status = 'active';

  v_weeks := greatest(1, round((v_prog.ends_on - v_prog.starts_on) / 7.0)::int);

  v_body := case v_reason
    when 'block_end' then
      'That is ' || v_weeks || ' weeks done on this plan. The next one is '
      || 'ready — same main lifts, since those are working, with a couple of '
      || 'new accessories. This first week is deliberately lighter so you '
      || 'start it fresh rather than carrying the last six weeks into it.'
    when 'returning_declared' then
      'Welcome back. Picking up where you left off — your loads are as you '
      || 'left them, and this first week is lighter so the first session back '
      || 'is not the hardest one you have had.'
    else
      'Good to see you. It has been ' || (v_layoff / 7) || ' weeks, so I have '
      || 'kept your lifts and made this week lighter to ease back in. If you '
      || 'have been training elsewhere and that feels too easy, just put the '
      || 'weight up — I will follow you.'
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


-- ── Where it runs ───────────────────────────────────────────────────────────
-- Block ends are checked on session finish alongside the level signal. A
-- return from a layoff cannot be — by definition no session has happened — so
-- train_screen's callers get roll_block_on_open() to call when the Train tab
-- loads. train_screen itself is STABLE and cannot write.
create or replace function roll_block_on_open()
returns text
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then return null; end if;
  begin
    return roll_block_if_due(v_uid);
  exception when others then
    raise warning 'block rollover failed for %: %', v_uid, sqlerrm;
    return null;
  end;
end $$;

grant execute on function roll_block_on_open() to authenticated;

create or replace function _on_session_completed() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  -- Each guarded on its own: neither a promotion check nor a block rollover
  -- may ever cost someone the session they just finished.
  begin
    perform propose_level_change(new.user_id);
  exception when others then
    raise warning 'level check failed for % after session %: %',
      new.user_id, new.id, sqlerrm;
  end;
  begin
    perform roll_block_if_due(new.user_id);
  exception when others then
    raise warning 'block rollover failed for % after session %: %',
      new.user_id, new.id, sqlerrm;
  end;
  return new;
end $$;
