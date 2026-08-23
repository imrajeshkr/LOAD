-- Plan 04 acceptance: progression must differ by experience, and an advanced
-- lifter stuck at one weight for three sessions must get a lighter bar.
--
-- Helper below fabricates N completed sessions for one exercise, all at the
-- same top weight, then reads back what train_screen() would prefill today.

savepoint prog;

create or replace function _seed_history(
  p_uid uuid, p_ex uuid, p_days int[], p_kg numeric, p_reps int, p_rir int
) returns void language plpgsql as $$
declare v_ws uuid; v_se uuid; d int;
begin
  foreach d in array p_days loop
    -- workout_sessions_check ties status='completed' to a non-null completed_at.
    insert into workout_sessions (user_id, title, performed_on, status,
                                  started_at, completed_at)
    values (p_uid, 'seed', user_today(p_uid) - d, 'completed',
            now() - (d || ' days')::interval,
            now() - (d || ' days')::interval + interval '1 hour')
    returning id into v_ws;

    insert into session_exercises (user_id, session_id, exercise_id, ordinal)
    values (p_uid, v_ws, p_ex, 1) returning id into v_se;

    insert into session_sets (user_id, session_exercise_id, set_number,
                              weight_kg, reps, rir, is_completed, kind)
    values (p_uid, v_se, 1, p_kg, p_reps, p_rir, true, 'working');
  end loop;
end $$;

DO $$
declare
  v_uid uuid; v_ex uuid; v_pd uuid; v_prog uuid;
  v_kg numeric; v_note text; v_deload boolean; v_items jsonb;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  -- A commercial-gym plan so Bench Press is definitely prescribed, scheduled
  -- for today so train_screen() has a session to describe.
  update training_profiles
     set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,2,3,4,5,6,7]::smallint[],
         goals=array['build_muscle']::training_goal[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  select pde.exercise_id, pde.program_day_id into v_ex, v_pd
    from program_day_exercises pde
    join program_days pd on pd.id = pde.program_day_id
    join exercises e on e.id = pde.exercise_id
   where pd.program_id = v_prog and e.slug = 'bench-press' limit 1;
  if v_ex is null then raise exception 'bench-press not in the generated plan'; end if;

  update scheduled_workouts set program_day_id = v_pd
   where user_id = v_uid and scheduled_for = user_today(v_uid);

  -- ── 1 · Intermediate, one session mid-range: hold the weight ─────────────
  perform _seed_history(v_uid, v_ex, array[2], 60, 8, 2);
  select (x->>'prefill_kg')::numeric into v_kg
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x
   where (x->>'exercise_id')::uuid = v_ex;
  if v_kg <> 60 then
    raise exception 'intermediate mid-range should hold 60, got %', v_kg;
  end if;
  raise notice 'intermediate, mid-range      -> holds at % kg', v_kg;
  delete from workout_sessions where user_id=v_uid and title='seed';

  -- ── 2 · Beginner, same history: linear, weight goes up anyway ────────────
  update training_profiles set experience='beginner'
   where user_id=v_uid and valid_to is null;
  perform _seed_history(v_uid, v_ex, array[2], 60, 8, 2);
  select (x->>'prefill_kg')::numeric, x->>'coach_note' into v_kg, v_note
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x
   where (x->>'exercise_id')::uuid = v_ex;
  if v_kg <= 60 then
    raise exception 'beginner should progress linearly past 60, got %', v_kg;
  end if;
  raise notice 'beginner, same history       -> % kg  ("%")', v_kg, v_note;
  -- to_char(..,'FM999990.9') renders a whole number as "60." — a dangling
  -- decimal point in copy the user reads.
  if v_note like '%. kg%' then
    raise exception 'malformed weight in copy: %', v_note;
  end if;
  delete from workout_sessions where user_id=v_uid and title='seed';

  -- ── 3 · Advanced, three sessions stuck at 100 kg: lighter bar ────────────
  update training_profiles set experience='advanced'
   where user_id=v_uid and valid_to is null;
  perform _seed_history(v_uid, v_ex, array[2,4,6], 100, 5, 0);
  select (x->>'prefill_kg')::numeric, x->>'coach_note', (x->>'is_deload')::boolean
    into v_kg, v_note, v_deload
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x
   where (x->>'exercise_id')::uuid = v_ex;
  if not coalesce(v_deload,false) then
    raise exception 'advanced stalled 3 sessions but no deload fired (kg=%)', v_kg;
  end if;
  if v_kg >= 100 then
    raise exception 'deload fired but weight did not drop: %', v_kg;
  end if;
  raise notice 'advanced, stalled 3x at 100  -> % kg', v_kg;
  raise notice '    note: "%"', v_note;
  if v_note ilike '%deload%' then
    raise exception 'the word "deload" leaked into user-facing copy';
  end if;

  -- ── 4 · Same stall, intermediate: holds, no deload (spec S7) ─────────────
  update training_profiles set experience='intermediate'
   where user_id=v_uid and valid_to is null;
  select (x->>'prefill_kg')::numeric, (x->>'is_deload')::boolean into v_kg, v_deload
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x
   where (x->>'exercise_id')::uuid = v_ex;
  if coalesce(v_deload,false) then
    raise exception 'intermediate must not auto-deload';
  end if;
  raise notice 'intermediate, same stall     -> holds at % kg, no deload', v_kg;

  -- ── 5 · Only two stalled sessions is not a stall ─────────────────────────
  update training_profiles set experience='advanced'
   where user_id=v_uid and valid_to is null;
  delete from workout_sessions where user_id=v_uid and title='seed';
  perform _seed_history(v_uid, v_ex, array[2,4], 100, 5, 0);
  select (x->>'is_deload')::boolean into v_deload
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x
   where (x->>'exercise_id')::uuid = v_ex;
  if coalesce(v_deload,false) then
    raise exception 'two sessions is a short history, not a stall';
  end if;
  raise notice 'advanced, only 2 sessions    -> no deload';

  raise notice 'PLAN 04 PROGRESSION ACCEPTANCE: PASS';
end $$;
rollback to savepoint prog;
