-- =============================================================================
-- LOAD v2 — dev seed data (NOT a migration; never ship)
--
-- Populates a realistic ~12-week history for the currently-active account so
-- every design screen has something to render: Progress (all seven panels),
-- the Train after-state, the Trainer thread, Profile stats. Idempotent —
-- re-running wipes the seeded window and rebuilds it.
--
-- Targets the user who owns the active program (the account you're signed into
-- on the simulator). Run once in the SQL Editor.
-- =============================================================================

do $$
declare
  v_user     uuid;
  v_start    date := current_date - 81;   -- 12 training weeks back (wk11 = today)
  v_week     int;
  v_sess     uuid;
  v_bench    numeric; v_squat numeric; v_reps int;
  v_pd       date; v_pl date; v_lg date;
begin
  select user_id into v_user
    from programs where status = 'active' order by created_at desc limit 1;
  if v_user is null then
    raise exception 'No active program — generate a plan in the app first.';
  end if;

  -- ── idempotency: clear the seeded window + today's stray in_progress ──────
  delete from workout_sessions
   where user_id = v_user
     and (title in ('Push day','Pull day','Leg day')
          or (status = 'in_progress' and performed_on = current_date));
  delete from body_measurements where user_id = v_user and measured_on >= v_start;
  delete from nutrition_entries  where user_id = v_user and logged_on  >= v_start;
  delete from coach_threads      where user_id = v_user and title = 'Trainer (seed)';
  delete from progress_photos    where user_id = v_user and note = 'seed';
  delete from training_pauses    where user_id = v_user and note = 'seed';
  delete from user_constraints   where user_id = v_user and note = 'seed';

  -- ── helper: one completed session, returns its id ────────────────────────
  create or replace function _seed_session(p_user uuid, p_title text, p_at timestamptz)
  returns uuid language plpgsql as $f$
  declare v_id uuid;
  begin
    insert into workout_sessions (user_id, title, status, started_at, completed_at)
    values (p_user, p_title, 'completed', p_at - interval '50 min', p_at)
    returning id into v_id;
    return v_id;
  end $f$;

  -- ── helper: one lift with N identical working sets ───────────────────────
  create or replace function _seed_lift(
    p_user uuid, p_session uuid, p_slug text, p_ord int,
    p_nsets int, p_kg numeric, p_reps int, p_rir int, p_effort text)
  returns void language plpgsql as $f$
  declare v_ex uuid; v_se uuid; i int;
  begin
    select id into v_ex from exercises where slug = p_slug and owner_id is null;
    if v_ex is null then return; end if;
    insert into session_exercises (user_id, session_id, exercise_id, ordinal,
                                   effort, entry_mode, is_unconfirmed)
    values (p_user, p_session, v_ex, p_ord,
            nullif(p_effort, '')::effort_answer, 'live', false)
    returning id into v_se;
    for i in 1 .. p_nsets loop
      insert into session_sets (user_id, session_exercise_id, set_number, kind,
                                weight_kg, reps, rir)
      values (p_user, v_se, i, 'working', p_kg, p_reps, p_rir);
    end loop;
  end $f$;

  -- ── 12 weeks × Push / Pull / Leg ─────────────────────────────────────────
  for v_week in 0 .. 11 loop
    v_pd := v_start + v_week * 7 + 0;   -- Push  (Mon)
    v_pl := v_start + v_week * 7 + 2;   -- Pull  (Wed)
    v_lg := v_start + v_week * 7 + 4;   -- Leg   (Fri)

    -- PUSH: bench progresses; accessories varied RIR to fill the histogram
    v_bench := 40 + v_week * 2.5;
    v_sess := _seed_session(v_user, 'Push day', v_pd + time '19:00');
    perform _seed_lift(v_user, v_sess, 'bench-press',      1, 4, v_bench, 8,  1, 'right');
    perform _seed_lift(v_user, v_sess, 'overhead-press',   2, 3, 30 + v_week*1.25, 9, 2, 'right');
    perform _seed_lift(v_user, v_sess, 'incline-db-press', 3, 3, 20 + v_week*1.0, 11, 2, '');
    perform _seed_lift(v_user, v_sess, 'tricep-pushdown',  4, 3, 20 + v_week*0.5, 13, 4, 'easy');

    -- PULL
    v_sess := _seed_session(v_user, 'Pull day', v_pl + time '19:00');
    perform _seed_lift(v_user, v_sess, 'barbell-row',  1, 4, 50 + v_week*2.0, 9, 1, 'right');
    perform _seed_lift(v_user, v_sess, 'lat-pulldown', 2, 3, 45 + v_week*1.5, 11, 2, '');
    perform _seed_lift(v_user, v_sess, 'face-pull',    3, 3, 15 + v_week*0.5, 15, 5, 'easy');
    perform _seed_lift(v_user, v_sess, 'barbell-curl', 4, 3, 25 + v_week*0.75, 11, 3, '');

    -- LEG: squat deliberately STALLS from week 8 (flat load, top of range) so
    -- the "Where are you stuck?" panel has something real to detect.
    if v_week < 8 then
      v_squat := 40 + v_week * 5; v_reps := 8;
    else
      v_squat := 75; v_reps := 12;   -- flat + top-of-range = stalled
    end if;
    v_sess := _seed_session(v_user, 'Leg day', v_lg + time '19:00');
    perform _seed_lift(v_user, v_sess, 'back-squat',        1, 4, v_squat, v_reps,
                       case when v_week >= 8 then 0 else 1 end,
                       case when v_week >= 8 then 'all' else 'right' end);
    perform _seed_lift(v_user, v_sess, 'romanian-deadlift', 2, 3, 60 + v_week*2.0, 9, 2, 'right');
    perform _seed_lift(v_user, v_sess, 'leg-press',         3, 3, 100 + v_week*5.0, 12, 2, '');
    perform _seed_lift(v_user, v_sess, 'leg-curl',          4, 3, 35 + v_week*1.0, 13, 4, 'easy');
  end loop;

  -- ── bodyweight: every 3 days, 84.0 → ~80.2 with noise ────────────────────
  insert into body_measurements (user_id, measured_on, weight_kg, source)
  select v_user, d::date,
         round((84.0 - (d::date - v_start) / 84.0 * 3.8
                + (case (d::date - v_start) % 3 when 0 then 0.4 when 1 then -0.3 else 0.15 end))::numeric, 1),
         'manual'
    from generate_series(v_start, current_date, interval '3 days') d
  on conflict (user_id, measured_on) do update set weight_kg = excluded.weight_kg;

  -- ── protein: last 21 days, most days hit, a couple missed ────────────────
  insert into nutrition_entries (user_id, logged_on, protein_g)
  select v_user, d::date,
         case when (d::date - v_start) % 6 = 0 then 90 else 130 + ((d::date - v_start) % 5) * 8 end
    from generate_series(current_date - 20, current_date, interval '1 day') d;

  insert into nutrition_targets (user_id, protein_g)
  select v_user, 144
   where not exists (select 1 from nutrition_targets
                      where user_id = v_user and valid_to is null);

  -- ── a flagged shoulder (feeds injury banner + trainer receipts) ──────────
  insert into user_constraints (user_id, joint_id, label, severity, side, note, active_from)
  select v_user, j.id, 'Cranky left shoulder', 'mild', 'left', 'seed', current_date - 30
    from joints j where j.slug = 'shoulder';

  -- ── two progress photos, 12 weeks apart ──────────────────────────────────
  insert into progress_photos (user_id, taken_on, storage_path, angle, note)
  values (v_user, v_start, 'seed/front-first.jpg', 'front', 'seed'),
         (v_user, current_date, 'seed/front-latest.jpg', 'front', 'seed');

  -- ── one past ended pause (illness), so "weeks off don't count" has data ──
  insert into training_pauses (user_id, started_on, ended_on, reason, note)
  values (v_user, current_date - 38, current_date - 34, 'illness', 'seed');

  -- ── trainer thread: weekly review, a stall decision, today's morning note ─
  declare
    v_thread uuid; v_m uuid;
  begin
    insert into coach_threads (user_id, title, last_message_at)
    values (v_user, 'Trainer (seed)', now()) returning id into v_thread;

    -- weekly review (2 weeks ago), with stat card
    insert into coach_messages (user_id, thread_id, role, content, category, created_at,
                                read_at, card)
    values (v_user, v_thread, 'assistant',
      'Three sessions, 6,140 kg moved. Bench and rows both climbed — the squat is the one to watch.',
      'weekly_review', now() - interval '14 days', now() - interval '14 days',
      '{"stats":[{"value":"3","label":"sessions"},{"value":"6,140","label":"kg moved"},{"value":"+2.5","label":"bench kg"}]}'::jsonb)
    returning id into v_m;

    -- the stalled-squat decision (5 days ago), receipts + needs attention
    insert into coach_messages (user_id, thread_id, role, content, category, created_at,
                                needs_attention, read_at)
    values (v_user, v_thread, 'assistant',
      'Your squat has sat at 75 kg for four sessions while you finish the top of the range. That is a stall, not a plateau — time to push it to 77.5 or drop a back-off set.',
      'decision', now() - interval '5 days', true, now() - interval '5 days')
    returning id into v_m;
    insert into coach_message_receipts (user_id, message_id, position, icon, label, source_kind) values
      (v_user, v_m, 0, 'fitness_center', '15 sets read',  'session'),
      (v_user, v_m, 1, 'calendar_month', '4 sessions',    'session'),
      (v_user, v_m, 2, 'trending_flat',  'flat at 75 kg', 'set');

    -- today's morning note — pinned, unread, with "what I read" receipts
    insert into coach_messages (user_id, thread_id, role, content, category, created_at,
                                pinned_until, card)
    values (v_user, v_thread, 'assistant',
      'Push day. Bench opens at 67.5 — you left two in the tank last time, so it should move. Keep the left shoulder honest on the overhead work.',
      'morning_note', now() - interval '3 hours', current_date, null)
    returning id into v_m;
    insert into coach_message_receipts (user_id, message_id, position, icon, label, source_kind) values
      (v_user, v_m, 0, 'history',                 'Read last Push day', 'session'),
      (v_user, v_m, 1, 'healing',                 'Shoulder flagged',   'constraint'),
      (v_user, v_m, 2, 'local_fire_department',   '3-day streak',       'streak');

    update coach_threads set last_message_at = now() where id = v_thread;
  end;

  -- ── profile: fill the v2 plan inputs so Profile + generation read right ──
  update training_profiles set
      goals               = array['build_muscle','strength']::training_goal[],
      goal_is_coach_choice = false,
      target_direction    = 'lose',
      target_weight_kg    = 76,
      training_weekdays   = array[1,3,5]::smallint[],
      bar_weight_kg       = 20,
      plate_sizes_kg      = array[20,15,10,5,2.5,1.25]::numeric[],
      has_benched         = true
   where user_id = v_user and valid_to is null;

  -- ── make TODAY a fresh, scheduled, un-started training day ───────────────
  -- The Train BEFORE-state (plan + morning note + Start button + upcoming) only
  -- shows when today has a scheduled_workout and NO completed session. So: clear
  -- today's completed Leg session, then schedule today + the next two training
  -- days off the active program, cycling its rotation.
  declare
    v_prog  uuid;
    v_days  uuid[];
    v_d     date := current_date;
    v_slot  int  := 0;
  begin
    select id into v_prog from programs
     where user_id = v_user and status = 'active' order by created_at desc limit 1;
    select array_agg(id order by ordinal) into v_days
      from program_days where program_id = v_prog;

    if v_prog is not null and v_days is not null then
      -- today reads as "to do", not "done"
      delete from workout_sessions where user_id = v_user and performed_on = current_date;
      -- re-seed the forward schedule cleanly
      delete from scheduled_workouts where user_id = v_user and scheduled_for >= current_date;

      -- today first (forced, whatever weekday it is), then next two on Mon/Wed/Fri
      while v_slot < 3 loop
        if v_d = current_date or extract(isodow from v_d)::int = any (array[1,3,5]) then
          insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
          values (v_user, v_prog,
                  v_days[(v_slot % array_length(v_days, 1)) + 1], v_d)
          on conflict do nothing;
          v_slot := v_slot + 1;
        end if;
        v_d := v_d + 1;
      end loop;
    end if;
  end;

  drop function _seed_session(uuid, text, timestamptz);
  drop function _seed_lift(uuid, uuid, text, int, int, numeric, int, int, text);

  raise notice 'Seeded 36 sessions + metrics for user %', v_user;
end $$;
