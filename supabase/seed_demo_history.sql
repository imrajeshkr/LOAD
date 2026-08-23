-- =============================================================================
-- Seed ~7 months of training history for one demo account.
--
--   psql -f supabase/seed_demo_history.sql      (via tool/db_apply.sh)
--
-- The point is not "1200 rows exist". It is that the app has something honest
-- to render: a lifter who started as a novice, added weight every session
-- until that stopped working, stalled, was moved onto intermediate
-- programming, took a holiday, came back, and kept going. Every screen in the
-- app — Progress charts, streaks, lift status, promotion history — reads that
-- shape rather than a flat line.
--
-- Realism the generator deliberately includes:
--   * linear novice gains that decelerate and then plateau, per lift
--   * a deload-and-rebuild around the plateau, which is what §8.1's promotion
--     test looks for
--   * a real level change part-way through, versioned on training_profiles
--   * ~12% of sessions missed, because nobody trains 100% of planned days
--   * a two-week holiday with nothing logged
--   * bodyweight that drifts, with day-to-day noise, not a clean ramp
--   * reps and RIR that move with proximity to the working max
--
-- Rerunnable: it clears the account first.
-- =============================================================================

do $$
declare
  v_uid       uuid;
  v_prog      uuid;
  v_day       date;
  v_today     date := current_date;
  v_from      date := current_date - 210;    -- ~7 months
  v_ws        uuid;
  v_se        uuid;
  v_pd        uuid;
  r           record;
  v_n         int := 0;
  v_kg        numeric;
  v_reps      int;
  v_rir       int;
  v_bw        numeric := 72.5;
  v_sets      int;
  v_setno     int;
  v_promoted  boolean := false;
  v_holiday_a date := current_date - 96;
  v_holiday_b date := current_date - 82;
  v_started   timestamptz;
  v_wd        smallint[] := array[1,3,5];   -- follows the profile, see promotion
  v_trained   boolean;
begin
  select id into v_uid from auth.users where email = 'rkumarmeena064@gmail.com';
  if v_uid is null then raise exception 'demo account not found'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  -- ── Wipe the account clean ────────────────────────────────────────────────
  delete from session_sets        where user_id = v_uid;
  delete from session_exercises   where user_id = v_uid;
  delete from workout_sessions    where user_id = v_uid;
  delete from body_measurements   where user_id = v_uid;
  delete from scheduled_workouts  where user_id = v_uid;
  delete from program_weekday_slots where user_id = v_uid;
  delete from exercise_swaps      where user_id = v_uid;
  delete from coach_proposals     where user_id = v_uid;
  delete from coach_messages      where user_id = v_uid;
  delete from program_day_exercises where program_day_id in (
    select pd.id from program_days pd join programs p on p.id = pd.program_id
     where p.user_id = v_uid);
  delete from program_days where program_id in (select id from programs where user_id = v_uid);
  delete from programs where user_id = v_uid;
  delete from training_pauses where user_id = v_uid;
  -- Keep only one training profile version; the promotion below adds the second.
  delete from training_profiles where user_id = v_uid and valid_to is not null;

  -- ── Where they started: a novice, three days a week ──────────────────────
  update training_profiles
     set experience = 'beginner', environment = 'commercial_gym',
         split_preference = 'full_body', training_weekdays = array[1,3,5]::smallint[],
         days_per_week = 3, goals = array['build_muscle']::training_goal[],
         goal = 'build_muscle', has_benched = false, bar_weight_kg = 20,
         intake_confirmed = true,
         valid_from = v_from::timestamptz
   where user_id = v_uid and valid_to is null;

  v_prog := bootstrap_user_program(v_uid);

  -- Per-lift working weight, carried across the whole history.
  create temp table if not exists _load (
    exercise_id uuid primary key,
    kg numeric, step numeric, ceiling_kg numeric, sessions int default 0
  ) on commit drop;
  delete from _load;

  -- Start and ceiling are scaled per lift, not uniformly. Every lift is
  -- prescribed at 20kg for a novice who has never benched (empty bar on
  -- barbell work), and multiplying all of them by the same factor produced a
  -- 70kg lateral raise. A dumbbell isolation movement starts light and stays
  -- light; a barbell hinge does neither.
  insert into _load (exercise_id, kg, step, ceiling_kg)
  select distinct on (pde.exercise_id) pde.exercise_id, b.start_kg,
         case when e.mechanic = 'isolation' then 1.25
              when e.pattern = 'legs'       then 5.0
              else                               2.5 end,
         b.start_kg * (case when e.mechanic = 'isolation' then 2.4
                            when e.pattern = 'legs'       then 4.5
                            else                               3.0 end)
           + (('x' || substr(md5(e.slug), 1, 4))::bit(16)::int % 8)
    from program_day_exercises pde
    join program_days pd on pd.id = pde.program_day_id
    join exercises e on e.id = pde.exercise_id
    cross join lateral (select case
             when e.load_type = 'bodyweight_reps' then 0
             when e.mechanic = 'isolation' then 7.5
             else greatest(coalesce(pde.target_weight_kg, 20), 20) end as start_kg) b
   where pd.program_id = v_prog;

  -- ── Walk the calendar ────────────────────────────────────────────────────
  v_day := v_from;
  while v_day <= v_today loop
    -- Mon / Wed / Fri, minus a holiday, minus the sessions real people skip.
    -- Read from v_wd rather than a literal: the promotion below moves this
    -- lifter from Mon/Wed/Fri to Mon/Tue/Thu/Fri, and hardcoding (1,3,5) left
    -- 77 sessions sitting on days the profile said were rest days. The app
    -- then correctly reported "2 of 4 done · +1 extra · 2 missed" every week,
    -- which looked like an app bug and was a seeding bug.
    -- A scheduled day and a trained day are different things. Scheduling only
    -- the days that were trained left skipped days with no program_day, so the
    -- week strip showed them as REST rather than missed — the plan has to say
    -- what you were meant to do before "missed" means anything.
    v_trained := not (v_day between v_holiday_a and v_holiday_b)
                 and (('x' || substr(md5(v_day::text), 1, 4))::bit(16)::int % 100) > 12;

    if extract(isodow from v_day)::int = any (v_wd) then
      -- Halfway through, linear progression has finished its job. Promote,
      -- which is what the real detector would have proposed here.
      if not v_promoted and v_day > v_from + 100 then
        update training_profiles set valid_to = v_day::timestamptz
         where user_id = v_uid and valid_to is null;
        insert into training_profiles (
          user_id, goal, experience, environment, split_preference, days_per_week,
          target_weight_kg, goals, goal_is_coach_choice, target_direction,
          training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched,
          intake_confirmed, valid_from)
        select user_id, goal, 'intermediate', environment, 'push_pull_legs', 4,
               target_weight_kg, goals, goal_is_coach_choice, target_direction,
               array[1,2,4,5]::smallint[], bar_weight_kg, plate_sizes_kg, true, true,
               v_day::timestamptz
          from training_profiles
         where user_id = v_uid and valid_to is not null
         order by valid_to desc limit 1;

        v_prog := bootstrap_user_program(v_uid);
        update programs set starts_on = v_day where id = v_prog;
        v_wd := array[1,2,4,5];   -- the new profile's training days

        -- Lifts already being trained keep their load; only lifts new to the
        -- rebuilt plan need a starting point. Gains slow after promotion.
        insert into _load (exercise_id, kg, step, ceiling_kg)
        select distinct on (pde.exercise_id) pde.exercise_id, b.start_kg,
               case when e.mechanic = 'isolation' then 1.25 else 2.5 end,
               b.start_kg * (case when e.mechanic = 'isolation' then 2.0 else 2.6 end)
          from program_day_exercises pde
          join program_days pd on pd.id = pde.program_day_id
          join exercises e on e.id = pde.exercise_id
          cross join lateral (select case
                   when e.load_type = 'bodyweight_reps' then 0
                   when e.mechanic = 'isolation' then 7.5
                   else greatest(coalesce(pde.target_weight_kg, 20), 20) end as start_kg) b
         where pd.program_id = v_prog
        on conflict (exercise_id) do nothing;

        v_promoted := true;
      end if;

      -- Take the day type from program_weekday_slots, which is how the app
      -- actually decides what a given weekday is. Cycling by session count
      -- instead produced Thursday = "Push day B" and Friday = "Push day A" —
      -- two push days back to back, and a weekday whose session changed week
      -- to week, which never happens in the real scheduler.
      select s.program_day_id into v_pd
        from program_weekday_slots s
       where s.user_id = v_uid
         and s.weekday = extract(isodow from v_day)::smallint
       limit 1;

      -- The promotion above may have just moved this lifter off the weekday we
      -- are standing on (Mon/Wed/Fri becomes Mon/Tue/Thu/Fri, so a Wednesday
      -- stops being a training day mid-iteration). Skip that one day rather
      -- than borrow another weekday's session, which would make one weekday
      -- carry two session types.
      if v_pd is null then
        v_day := v_day + 1;
        continue;
      end if;

      -- performed_on is stamped from started_at by a trigger, so the timestamp
      -- is what actually dates the session.
      v_started := (v_day + time '18:30') at time zone 'Asia/Kolkata';
      -- bootstrap only materialises the schedule FORWARD from the day it runs,
      -- so history had no scheduled_workouts at all and every past day in the
      -- week strip fell back to the "REST" label. A real account accumulates
      -- these as the weeks pass; the seed has to lay them down itself.
      insert into scheduled_workouts (user_id, program_id, program_day_id,
                                      scheduled_for, status)
      values (v_uid, v_prog, v_pd, v_day,
              (case when v_trained then 'completed' else 'missed' end)::schedule_status)
      on conflict (user_id, scheduled_for, program_day_id) do nothing;

      -- Scheduled but not done: a genuine missed session.
      if not v_trained then
        v_day := v_day + 1;
        continue;
      end if;

      insert into workout_sessions (user_id, title, status, started_at, completed_at)
      values (v_uid,
              coalesce((select label from program_days where id = v_pd), 'Session'),
              'completed', v_started, v_started + interval '58 minutes')
      returning id into v_ws;

      for r in
        select pde.exercise_id, pde.ordinal, pde.sets_target, pde.rep_low, pde.rep_high,
               e.load_type::text as lt
          from program_day_exercises pde
          join exercises e on e.id = pde.exercise_id
         where pde.program_day_id = v_pd
         order by pde.ordinal
      loop
        insert into session_exercises (user_id, session_id, exercise_id, ordinal)
        values (v_uid, v_ws, r.exercise_id, r.ordinal)
        returning id into v_se;

        select kg into v_kg from _load where exercise_id = r.exercise_id;
        if v_kg is null then
          v_kg := 20; insert into _load (exercise_id, kg, step, ceiling_kg)
                      values (r.exercise_id, 20, 2.5, 60);
        end if;

        v_sets := coalesce(r.sets_target, 3);
        for v_setno in 1 .. v_sets loop
          -- Reps drift down across sets as fatigue accumulates; RIR follows
          -- how close the working weight is to where this lift tops out.
          v_reps := greatest(r.rep_low,
                      r.rep_high - (v_setno - 1)
                      - (('x' || substr(md5(v_day::text || r.exercise_id::text || v_setno), 1, 4))::bit(16)::int % 2));
          select case when kg >= ceiling_kg * 0.95 then 0
                      when kg >= ceiling_kg * 0.85 then 1
                      else 2 end
            into v_rir from _load where exercise_id = r.exercise_id;

          insert into session_sets (user_id, session_exercise_id, set_number,
                                    weight_kg, reps, rir, is_completed, kind)
          values (v_uid, v_se, v_setno,
                  case when r.lt = 'bodyweight_reps' then null else v_kg end,
                  v_reps, v_rir, true, 'working');
        end loop;

        -- Progress the lift, decelerating as it approaches its ceiling, and
        -- reset ~10% on a hard stall — which is exactly the pattern the
        -- promotion detector looks for.
        update _load set
          sessions = sessions + 1,
          kg = case
                 when kg >= ceiling_kg then round((kg * 0.9) / 2.5) * 2.5
                 when kg >= ceiling_kg * 0.9 then
                   case when sessions % 3 = 0 then kg + step else kg end
                 else kg + step
               end
         where exercise_id = r.exercise_id;
      end loop;

      v_n := v_n + 1;
    end if;

    -- Bodyweight most mornings, drifting up on a lean bulk with real noise.
    if (('x' || substr(md5('bw' || v_day::text), 1, 4))::bit(16)::int % 100) > 55 then
      insert into body_measurements (user_id, measured_on, weight_kg, source)
      values (v_uid, v_day,
              round((v_bw + ((('x' || substr(md5(v_day::text), 1, 4))::bit(16)::int % 100) - 50) / 100.0)::numeric, 1),
              'manual')
      on conflict (user_id, measured_on) do nothing;
    end if;
    v_bw := v_bw + 0.021;      -- ~+4.4 kg across seven months

    v_day := v_day + 1;
  end loop;

  -- Leave the account on a current, correctly-versioned plan.
  update programs set generator_version = 3 where user_id = v_uid and status = 'active';

  raise notice 'seeded % sessions for %', v_n, v_uid;
end $$;
