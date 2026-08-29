savepoint add_ex;
DO $$
declare
  v_uid uuid; v_uid2 uuid;
  v_prog uuid; v_prog2 uuid;
  v_day uuid; v_day2 uuid;
  v_ex uuid; v_ex2 uuid; v_ex3 uuid;
  v_max_ord int; v_new_ord int; v_cnt int;
  v_cable uuid;
  v_mine uuid;
  v_found boolean;
begin
  select id into v_uid  from profiles order by created_at limit 1;
  select id into v_uid2 from profiles order by created_at limit 1 offset 1;

  -- ── set up two lifters, each with an active program ────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  perform set_config('role', 'authenticated', true);
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[], goals=array['build_muscle']::training_goal[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);
  select pd.id into v_day from program_days pd
   where pd.program_id = v_prog order by pd.ordinal limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_uid2)::text, true);
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[2,4,6]::smallint[], goals=array['build_muscle']::training_goal[]
   where user_id=v_uid2 and valid_to is null;
  v_prog2 := bootstrap_user_program(v_uid2);
  select pd.id into v_day2 from program_days pd
   where pd.program_id = v_prog2 order by pd.ordinal limit 1;

  -- back to lifter 1 for the rest of the test
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  -- ── appends with the next ordinal ───────────────────────────────────────
  select coalesce(max(ordinal), 0) into v_max_ord
    from program_day_exercises where program_day_id = v_day;

  select id into v_ex from exercises
   where owner_id is null and is_core
     and id not in (select exercise_id from program_day_exercises where program_day_id = v_day)
   limit 1;
  if v_ex is null then raise exception 'setup: no spare core exercise to add'; end if;

  perform add_day_exercise(v_day, v_ex);
  select ordinal into v_new_ord from program_day_exercises
   where program_day_id = v_day and exercise_id = v_ex;
  if v_new_ord is distinct from v_max_ord + 1 then
    raise exception 'expected ordinal %, got %', v_max_ord + 1, v_new_ord;
  end if;
  raise notice 'append          -> ordinal % (was max %)', v_new_ord, v_max_ord;

  -- ── adding the same exercise twice is a no-op ───────────────────────────
  perform add_day_exercise(v_day, v_ex);
  select count(*) into v_cnt from program_day_exercises
   where program_day_id = v_day and exercise_id = v_ex;
  if v_cnt <> 1 then
    raise exception 'adding twice produced % rows, expected 1', v_cnt;
  end if;
  raise notice 'add twice       -> no-op, one row';

  -- ── adding to someone else's program day is refused ─────────────────────
  select id into v_ex2 from exercises
   where owner_id is null and is_core
     and id not in (select exercise_id from program_day_exercises where program_day_id = v_day2)
   limit 1;
  begin
    perform add_day_exercise(v_day2, v_ex2);
    raise exception 'add_day_exercise let lifter 1 write into lifter 2''s program day';
  exception when others then
    if sqlerrm like '%not your program day%' then
      raise notice 'other''s day     -> refused, as it must be';
    else
      raise; -- an unexpected error is still a bug worth seeing
    end if;
  end;

  -- ── browse_exercises returns a lifter's own private exercise even when ──
  -- its equipment is not in their environment ─────────────────────────────
  update training_profiles set environment = 'bodyweight_only'
   where user_id = v_uid and valid_to is null;

  select id into v_cable from equipment where slug = 'cable';

  insert into exercises (slug, name, pattern, load_type, owner_id, is_core, min_experience)
  values ('my-cable-thing-'||substr(md5(random()::text),1,6), 'My Cable Thing',
          'pull', 'weight_reps', v_uid, false, 'advanced')
  returning id into v_mine;

  insert into exercise_equipment (exercise_id, equipment_id, is_required)
  values (v_mine, v_cable, true);

  select exists (select 1 from browse_exercises() where exercise_id = v_mine) into v_found;
  if not v_found then
    raise exception 'browse_exercises dropped a private exercise for equipment/level the app cannot enforce on its own gym';
  end if;
  raise notice 'own exercise    -> visible despite missing equipment/experience';

  raise notice 'V2_0054 ADD DAY EXERCISE: PASS';
end $$;
rollback to savepoint add_ex;
