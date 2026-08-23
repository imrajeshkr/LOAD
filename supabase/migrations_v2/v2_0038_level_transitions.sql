-- =============================================================================
-- v2_0038 — level transitions (Plan 06, spec §8.1, §8.2, §13.6, §13.7)
--
-- Training age is not calendar time. §8.1's definition is which progression
-- scheme still works, which makes the detector fall out of data we already
-- have: a beginner graduates when linear progression stops paying.
--
-- Nothing here changes anyone's plan on its own. A transition is a proposal
-- (§8.2), and the label never reaches the user (§13.7) — the copy describes
-- the behaviour that changes, because "do you want to become advanced?" is not
-- a question anyone can answer honestly about themselves.
-- =============================================================================



-- ── Did a stall survive a deload? ───────────────────────────────────────────
-- §8.1 condition 3, and the one that separates "adaptation has run out" from
-- "this lifter was tired for a fortnight". Derived from history rather than
-- recorded, exactly like the deload itself (v2_0030): a drop of >=7% off a
-- peak, followed by a session that got back to that peak.
create or replace function deload_survived(p_user_id uuid, p_exercise_id uuid)
returns boolean language sql stable as $$
  with s as (
    select ws.performed_on, max(ss.weight_kg) as top_kg
      from session_sets ss
      join session_exercises se on se.id = ss.session_exercise_id
      join workout_sessions  ws on ws.id = se.session_id
     where se.user_id = p_user_id and se.exercise_id = p_exercise_id
       and ws.status = 'completed' and ss.is_completed and ss.kind = 'working'
     group by ws.performed_on
  ),
  r as (
    select performed_on, top_kg,
           max(top_kg) over (order by performed_on
                             rows between unbounded preceding and 1 preceding) as peak_before
      from s
  )
  select exists (
    select 1
      from r d
     where d.peak_before is not null
       and d.top_kg <= d.peak_before * 0.93
       and exists (select 1 from s s2
                    where s2.performed_on > d.performed_on
                      and s2.top_kg >= d.peak_before));
$$;


-- ── The signal ──────────────────────────────────────────────────────────────
create or replace function level_promotion_signal(p_user_id uuid)
returns table (
  eligible    boolean,
  from_level  experience_level,
  to_level    experience_level,
  evidence    int,          -- how many main lifts back the case; drives §13.6
  weeks       int,
  deload_ok   boolean,
  lifts       text[]
)
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_exp   experience_level;
  v_weeks int;
begin
  select coalesce(experience, 'intermediate') into v_exp
    from training_profiles where user_id = p_user_id and valid_to is null;

  select count(distinct date_trunc('week', performed_on))::int into v_weeks
    from workout_sessions
   where user_id = p_user_id and status = 'completed';

  if v_exp = 'beginner' then
    -- Stalled MAIN lifts only: an accessory plateauing says nothing about
    -- whether linear progression has finished its job.
    return query
    with stalled as (
      select ls.exercise_name, ls.exercise_id
        from lift_status(p_user_id) ls
        join exercises e on e.id = ls.exercise_id
       where ls.status = 'stalled' and e.mechanic = 'compound'
    )
    select (select count(*) from stalled) >= 2
             and v_weeks >= 8
             and exists (select 1 from stalled s
                          where deload_survived(p_user_id, s.exercise_id)),
           'beginner'::experience_level,
           'intermediate'::experience_level,
           (select count(*)::int from stalled),
           v_weeks,
           exists (select 1 from stalled s
                    where deload_survived(p_user_id, s.exercise_id)),
           coalesce((select array_agg(exercise_name order by exercise_name) from stalled),
                    '{}');
    return;
  end if;

  if v_exp = 'intermediate' then
    -- §8.1: deliberately not automatic. The bar is time under the bar plus
    -- genuinely slow gains — advanced means more volume and scheduled
    -- deloads, which is a worse deal for anyone still progressing faster.
    return query
    with mains as (
      select ls.exercise_name, ls.net_change_kg
        from lift_status(p_user_id, (current_date - 84)) ls
        join exercises e on e.id = ls.exercise_id
       where e.mechanic = 'compound' and ls.sessions_counted >= 6
    ),
    creeping as (
      select * from mains where coalesce(net_change_kg, 0) < 3
    )
    select v_weeks >= 78
             and (select count(*) from mains) >= 2
             and (select count(*) from creeping) >= (select count(*) from mains),
           'intermediate'::experience_level,
           'advanced'::experience_level,
           (select count(*)::int from creeping),
           v_weeks,
           true,
           coalesce((select array_agg(exercise_name order by exercise_name) from creeping),
                    '{}');
    return;
  end if;

  -- Advanced is the top of the ladder, and §8.1 has no automatic demotion.
  return query select false, v_exp, v_exp, 0, v_weeks, false, '{}'::text[];
end $$;


-- ── Proposing it ────────────────────────────────────────────────────────────
-- §13.6: evaluate on session finish, but never interrupt a session. This is
-- safe to call repeatedly — the snooze rules below decide whether anything is
-- actually created.
create or replace function propose_level_change(p_user_id uuid)
returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_sig      record;
  v_last     record;
  v_declines int;
  v_thread   uuid;
  v_msg      uuid;
  v_body     text;
begin
  select * into v_sig from level_promotion_signal(p_user_id);
  if not v_sig.eligible then return null; end if;

  -- Never stack proposals.
  if exists (select 1 from coach_proposals
              where user_id = p_user_id and kind = 'level_change' and status = 'pending')
  then return null; end if;

  -- §13.6: "A coach who keeps asking the same question is nagging."
  select count(*) into v_declines
    from coach_proposals
   where user_id = p_user_id and kind = 'level_change' and status = 'rejected';

  select payload, resolved_at into v_last
    from coach_proposals
   where user_id = p_user_id and kind = 'level_change' and status = 'rejected'
   order by resolved_at desc limit 1;

  if v_last.resolved_at is not null then
    -- Two refusals means stop asking for a quarter, not ask again next month.
    if v_declines >= 2 and v_last.resolved_at > now() - interval '12 weeks' then
      return null;
    end if;
    if v_last.resolved_at > now() - interval '4 weeks' then
      return null;
    end if;
    -- Re-ask only when the case got stronger, never on a timer alone.
    if coalesce((v_last.payload->>'evidence')::int, 0) >= v_sig.evidence then
      return null;
    end if;
  end if;

  select id into v_thread from coach_threads
   where user_id = p_user_id order by last_message_at desc nulls last limit 1;
  if v_thread is null then
    insert into coach_threads (user_id, title) values (p_user_id, 'Coach')
    returning id into v_thread;
  end if;

  -- §13.7: describe the change, never the tier. No "you are now intermediate".
  if v_sig.to_level = 'intermediate' then
    v_body := case
      when array_length(v_sig.lifts, 1) = 1
        then 'Your ' || v_sig.lifts[1] || ' has stopped climbing week to week. '
      else array_to_string(v_sig.lifts[1:2], ' and ')
           || ' have both stopped climbing week to week. '
      end
      || 'That is not failure — it is what happens when adding weight every '
      || 'session has given you everything it can. Want me to change how your '
      || 'training moves? A bit more work each week, and the weight goes up '
      || 'across the week instead of every session.';
  else
    v_body := 'Your main lifts have been creeping rather than climbing for a '
      || 'while now. Want me to add a lighter week every fourth week and push '
      || 'your volume up a little? That tends to get things moving again when '
      || 'steady progress runs out.';
  end if;

  insert into coach_messages (user_id, thread_id, role, content, category, needs_attention)
  values (p_user_id, v_thread, 'assistant', v_body, 'decision', true)
  returning id into v_msg;

  update coach_threads set last_message_at = now() where id = v_thread;

  insert into coach_proposals (user_id, message_id, kind, payload, status)
  values (p_user_id, v_msg, 'level_change',
          jsonb_build_object('from', v_sig.from_level, 'to', v_sig.to_level,
                             'evidence', v_sig.evidence, 'weeks', v_sig.weeks,
                             'lifts', to_jsonb(v_sig.lifts),
                             -- The trainer screen reads payload.actions for its
                             -- two buttons. Phrased as answers to the question
                             -- asked, and still without naming a tier.
                             'actions', jsonb_build_array('Yes, change it', 'Not yet')),
          'pending')
  returning id into v_msg;

  return v_msg;
end $$;


-- ── Resolving it ────────────────────────────────────────────────────────────
create or replace function resolve_level_change(p_proposal_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_p   record;
  v_to  experience_level;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  select * into v_p from coach_proposals
   where id = p_proposal_id and user_id = v_uid and kind = 'level_change';
  if not found then raise exception 'no such proposal'; end if;
  if v_p.status <> 'pending' then raise exception 'proposal already resolved'; end if;

  if not p_accept then
    update coach_proposals set status = 'rejected', resolved_at = now()
     where id = p_proposal_id;
    return;
  end if;

  v_to := (v_p.payload->>'to')::experience_level;

  -- §8.2: close the current row and insert a new one, using the versioning
  -- that has been sitting unused. The old row stops being current rather than
  -- being overwritten, so the lifter's journey is recoverable — which is what
  -- lets Progress eventually say "you became an intermediate lifter in March".
  update training_profiles set valid_to = now()
   where user_id = v_uid and valid_to is null;

  insert into training_profiles (
    user_id, goal, experience, environment, split_preference, days_per_week,
    target_weight_kg, target_date, goals, goal_is_coach_choice, target_direction,
    training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched, intake_confirmed)
  select user_id, goal, v_to, environment, split_preference, days_per_week,
         target_weight_kg, target_date, goals, goal_is_coach_choice, target_direction,
         training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched, intake_confirmed
    from training_profiles
   where user_id = v_uid and valid_to is not null
   order by valid_to desc limit 1;

  update coach_proposals set status = 'confirmed', resolved_at = now()
   where id = p_proposal_id;

  -- The level drives volume and exercise filtering, so the plan has to be
  -- rebuilt for the change to mean anything.
  perform bootstrap_user_program(v_uid);
end $$;

revoke all on function resolve_level_change(uuid, boolean) from public;
grant execute on function resolve_level_change(uuid, boolean) to authenticated;
grant execute on function level_promotion_signal(uuid) to authenticated;
grant execute on function deload_survived(uuid, uuid) to authenticated;
