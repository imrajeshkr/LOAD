-- LOAD — dummy data for a test account, v2 schema.
--
-- HOW TO USE
--   1. Set the email below to the account you signed up with in the app.
--   2. Run the whole file in the Supabase SQL Editor.
--   3. Re-running is safe: it wipes this user's generated rows first.
--
-- Generates ~9 weeks of history on a Push/Pull/Legs rotation with progressive
-- overload on the main lifts, a slow bodyweight decline, and daily protein
-- logs with a few realistic missed days.
--
-- Requires migrations 0003–0006 and the catalog seed to have run first.

do $$
declare
  v_email   text := 'rajesh.test4@example.com';   -- << CHANGE ME
  v_user    uuid;
  v_units   unit_system;
  v_session uuid;
  v_sex     uuid;
  v_date    date;
  v_week    int;
  v_day     int;
  v_set     int;
  v_label   text;
  v_pattern text;
  v_ex      record;
  v_ordinal int;
  v_weight  numeric;
  v_reps    int;
  v_bw      numeric := 83.8;
  v_protein int;
begin
  select id into v_user from auth.users where email = v_email;
  if v_user is null then
    raise exception 'No auth user with email %. Sign up in the app first.', v_email;
  end if;

  -- ── wipe this user's generated history (catalog is untouched) ──────────
  delete from session_sets       where user_id = v_user;
  delete from session_exercises  where user_id = v_user;
  delete from workout_sessions   where user_id = v_user;
  delete from body_measurements  where user_id = v_user;
  delete from nutrition_entries  where user_id = v_user;
  delete from coach_proposals    where user_id = v_user;
  delete from coach_messages     where user_id = v_user;
  delete from coach_threads      where user_id = v_user;

  -- ── make sure the profile rows exist and are sensible ──────────────────
  insert into profiles (id, display_name, timezone)
       values (v_user, 'Test Lifter', 'Asia/Kolkata')
  on conflict (id) do update set timezone = excluded.timezone;

  insert into user_preferences (user_id) values (v_user)
  on conflict (user_id) do nothing;

  select units into v_units from user_preferences where user_id = v_user;

  if not exists (select 1 from training_profiles where user_id = v_user and valid_to is null) then
    insert into training_profiles
      (user_id, goal, experience, environment, split_preference, days_per_week, target_weight_kg)
    values (v_user, 'build_muscle', 'intermediate', 'commercial_gym', 'push_pull_legs', 4, 78);
  end if;

  -- A flagged shoulder, so the injury warnings have something to show.
  if not exists (select 1 from user_constraints where user_id = v_user and active_to is null) then
    insert into user_constraints (user_id, joint_id, label, severity, side)
    select v_user, id, 'Cranky left shoulder on heavy overhead work', 'moderate', 'left'
      from joints where slug = 'shoulder';
  end if;

  insert into nutrition_targets (user_id, protein_g, calories)
  select v_user, 145, 2600
   where not exists (select 1 from nutrition_targets where user_id = v_user and valid_to is null);

  -- ── a program, so Today has something real to render ───────────────────
  perform bootstrap_user_program(v_user);

  -- ── 9 weeks of sessions, 3 per week ────────────────────────────────────
  for v_week in reverse 8 .. 0 loop
    for v_day in 0 .. 2 loop
      v_date := current_date - (v_week * 7) - (6 - v_day * 2);
      exit when v_date > current_date;

      v_pattern := (array['push', 'pull', 'legs'])[v_day + 1];
      v_label   := (array['Push Day', 'Pull Day', 'Leg Day'])[v_day + 1];

      insert into workout_sessions
        (user_id, title, performed_on, started_at, completed_at, status, session_rpe)
      values (v_user, v_label, v_date,
              v_date + time '18:00', v_date + time '19:10', 'completed',
              7 + (v_week % 3) * 0.5)
      returning id into v_session;

      v_ordinal := 0;
      for v_ex in
        select e.id, e.slug, e.default_rep_low, e.default_rep_high
          from exercises e
         where e.owner_id is null and e.pattern = v_pattern
           and e.load_type = 'weight_reps'
         order by e.name
         limit 4
      loop
        v_ordinal := v_ordinal + 1;

        insert into session_exercises (user_id, session_id, exercise_id, ordinal)
        values (v_user, v_session, v_ex.id, v_ordinal)
        returning id into v_sex;

        -- Progressive overload: heavier as the weeks advance, with the big
        -- compounds starting higher than the accessories.
        v_weight := case
          when v_ex.slug in ('bench-press','back-squat','deadlift','barbell-row')
            then 60 + (8 - v_week) * 2.5
          when v_ex.slug in ('overhead-press','front-squat','romanian-deadlift')
            then 35 + (8 - v_week) * 1.5
          else 16 + (8 - v_week) * 1.0
        end;
        -- Squats and deadlifts are simply heavier.
        if v_ex.slug in ('back-squat','deadlift') then v_weight := v_weight + 30; end if;

        v_reps := coalesce(v_ex.default_rep_low, 8) + 1;

        for v_set in 1 .. (case when v_ordinal = 1 then 4 else 3 end) loop
          insert into session_sets
            (user_id, session_exercise_id, set_number, kind, weight_kg, reps, rpe)
          values (v_user, v_sex, v_set, 'working',
                  round(v_weight::numeric, 1),
                  greatest(1, v_reps - (v_set / 3)),
                  7 + v_set * 0.5);
        end loop;
      end loop;

      -- one weigh-in per training day, drifting down
      v_bw := v_bw - 0.06;
      insert into body_measurements (user_id, measured_on, weight_kg)
      values (v_user, v_date, round(v_bw::numeric, 1))
      on conflict (user_id, measured_on) do update set weight_kg = excluded.weight_kg;
    end loop;
  end loop;

  -- ── protein, most days, with a few realistic misses ────────────────────
  for v_day in reverse 62 .. 0 loop
    v_date := current_date - v_day;
    continue when v_day % 11 = 0;                    -- missed logging
    v_protein := 120 + ((v_day * 7) % 45);
    insert into nutrition_entries (user_id, logged_on, logged_at, label, protein_g)
    values (v_user, v_date, v_date + time '20:30', 'Daily total', v_protein);
  end loop;

  -- ── an opening coach message so the thread isn't empty ─────────────────
  insert into coach_threads (user_id, title) values (v_user, 'Coach')
  returning id into v_session;

  insert into coach_messages (user_id, thread_id, role, content)
  values (v_user, v_session, 'assistant',
          'I''m your coach — ask me anything, or just tell me what you did after '
          || 'training and I''ll log it for you.');

  raise notice 'Seeded % — % sessions, % sets.',
    v_email,
    (select count(*) from workout_sessions where user_id = v_user),
    (select count(*) from session_sets where user_id = v_user);
end $$;
