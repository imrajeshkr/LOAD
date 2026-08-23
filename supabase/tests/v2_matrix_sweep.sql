-- =============================================================================
-- Generator coverage sweep — every plan shape a user can ask for.
--
-- NOT part of the CI suite: it runs a few hundred bootstraps and takes minutes.
-- Run it by hand after any change to plan generation:
--     ./tool/db_test.sh supabase/tests/v2_matrix_sweep.sql
--
-- WHAT THIS DOES AND DOES NOT CLAIM
-- It does not tune the §6 volume table and cannot. Synthetic histories are
-- generated from an assumed model of how people respond to training, so
-- "tuning" against them recovers the assumption, not the truth. That table
-- needs real lifters or published literature.
--
-- What it does prove is structural: across every combination of training age,
-- environment, goal, day count, split and injury, the generator always
-- produces a plan a coach would recognise — no empty days, no one-lift
-- sessions, no two-hour sessions, nothing above the lifter's training age,
-- nothing severe on a joint they flagged, and no muscle silently dropped.
--
-- That is the class of bug that has actually bitten this project: bodyweight
-- plans with an empty leg day, Upper/Lower with no pull work, abs trained by
-- no split at all. All three were found by accident. This finds them on
-- purpose.
-- =============================================================================

savepoint sweep;
DO $$
declare
  v_uid    uuid;
  v_prog   uuid;
  v_exp    text;
  v_env    text;
  v_goal   text;
  v_split  text;
  v_days   int;
  v_inj    int;
  v_wd     smallint[];
  v_runs   int := 0;
  v_fail   int := 0;
  v_shoulder uuid;
  v_knee     uuid;
  v_case   text;
  r        record;
  v_empty  int;
  v_min    int;
  v_maxset int;
  v_above  int;
  v_unsafe int;
  v_ext    int;
  v_gap    int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  select id into v_shoulder from joints where slug='shoulder';
  select id into v_knee     from joints where slug='knee';
  delete from exercise_swaps where user_id = v_uid;

  foreach v_exp in array array['beginner','intermediate','advanced'] loop
  foreach v_env in array array['commercial_gym','home_gym','bodyweight_only'] loop
  foreach v_split in array array['full_body','upper_lower','push_pull_legs'] loop
  for v_days in 2..6 loop
  for v_inj in 0..1 loop

    v_wd := (select array_agg(d::smallint) from generate_series(1, v_days) d);

    delete from user_constraints where user_id = v_uid;
    if v_inj = 1 then
      insert into user_constraints (user_id, joint_id, label, severity, active_from)
      values (v_uid, v_shoulder, 'sweep shoulder', 'mild', current_date),
             (v_uid, v_knee,     'sweep knee',     'mild', current_date);
    end if;

    update training_profiles
       set experience = v_exp::experience_level,
           environment = v_env::train_environment,
           split_preference = v_split::split_type,
           training_weekdays = v_wd,
           days_per_week = v_days,
           goals = array['build_muscle']::training_goal[],
           has_benched = true
     where user_id = v_uid and valid_to is null;

    v_case := format('%s/%s/%s/%sd/inj=%s', v_exp, v_env, v_split, v_days, v_inj);
    v_runs := v_runs + 1;

    begin
      v_prog := bootstrap_user_program(v_uid);
    exception when others then
      raise notice 'FAIL % — bootstrap raised: %', v_case, sqlerrm;
      v_fail := v_fail + 1;
      continue;
    end;

    select count(*) into v_empty from program_days pd
     where pd.program_id = v_prog
       and not exists (select 1 from program_day_exercises x where x.program_day_id = pd.id);

    select min(c), max(s) into v_min, v_maxset from (
      select count(*) c, coalesce(sum(pde.sets_target),0) s
        from program_days pd
        left join program_day_exercises pde on pde.program_day_id = pd.id
       where pd.program_id = v_prog group by pd.id) t;

    select count(*) into v_above from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join exercises e on e.id = pde.exercise_id
     where pd.program_id = v_prog and e.min_experience > v_exp::experience_level;

    select count(*) into v_unsafe from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join exercise_joints ej on ej.exercise_id = pde.exercise_id
      join user_constraints uc on uc.joint_id = ej.joint_id and uc.user_id = v_uid
                              and uc.active_to is null
     where pd.program_id = v_prog and ej.stress_level = 'severe';

    select count(*) into v_ext from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join exercises e on e.id = pde.exercise_id
     where pd.program_id = v_prog and not e.is_core;

    -- Every movement pattern the lifter CAN train must actually be trained.
    -- This is the check that matters most: Upper/Lower shipped with no pull
    -- work at all, and no split trained abs, and neither showed up as an empty
    -- day or a short session. Measured against what is reachable for this
    -- environment and training age, so a pattern with no available lifts is
    -- not counted against the plan — that is the catalog's problem, not the
    -- generator's.
    select count(*) into v_gap from (
      select e.pattern from exercises e
       where e.owner_id is null and e.is_core
         and e.load_type in ('weight_reps','bodyweight_reps')
         and e.min_experience <= v_exp::experience_level
         and not exists (
               select 1 from exercise_equipment ee
                where ee.exercise_id = e.id and ee.is_required
                  and not exists (select 1 from environment_equipment env
                                   where env.equipment_id = ee.equipment_id
                                     and env.environment = v_env::train_environment))
         and not exists (
               select 1 from exercise_joints ej
                 join user_constraints uc on uc.joint_id = ej.joint_id
                                         and uc.user_id = v_uid
                                         and uc.active_to is null
                where ej.exercise_id = e.id and ej.stress_level = 'severe')
       group by e.pattern
      except
      select e2.pattern from program_day_exercises pde
        join program_days pd on pd.id = pde.program_day_id
        join exercises e2 on e2.id = pde.exercise_id
       where pd.program_id = v_prog
       group by e2.pattern) g;

    if v_empty > 0 then
      raise notice 'FAIL % — % empty day(s)', v_case, v_empty; v_fail := v_fail + 1;
    elsif v_min < 2 then
      raise notice 'FAIL % — a day has only % lift(s)', v_case, v_min; v_fail := v_fail + 1;
    elsif v_maxset > 30 then
      raise notice 'FAIL % — a session has % sets', v_case, v_maxset; v_fail := v_fail + 1;
    elsif v_above > 0 then
      raise notice 'FAIL % — % lift(s) above training age', v_case, v_above; v_fail := v_fail + 1;
    elsif v_unsafe > 0 then
      raise notice 'FAIL % — % lift(s) severe on a flagged joint', v_case, v_unsafe;
      v_fail := v_fail + 1;
    elsif v_ext > 0 then
      raise notice 'FAIL % — % Extended lift(s) auto-prescribed', v_case, v_ext;
      v_fail := v_fail + 1;
    elsif v_gap > 0 then
      raise notice 'FAIL % — % trainable pattern(s) never trained', v_case, v_gap;
      v_fail := v_fail + 1;
    end if;

  end loop; end loop; end loop; end loop; end loop;

  -- Goals affect prescription rather than shape, so they get their own pass.
  foreach v_goal in array array['build_muscle','strength','lose_fat',
                                'general_health','recomposition'] loop
    update training_profiles
       set goals = array[v_goal]::training_goal[], experience='intermediate',
           environment='commercial_gym', split_preference='push_pull_legs',
           training_weekdays=array[1,2,4,5]::smallint[], days_per_week=4
     where user_id = v_uid and valid_to is null;
    delete from user_constraints where user_id = v_uid;
    v_runs := v_runs + 1;
    v_prog := bootstrap_user_program(v_uid);
    select min(rep_low), max(rep_high), max(rest_seconds) into v_min, v_maxset, v_above
      from program_day_exercises pde join program_days pd on pd.id=pde.program_day_id
     where pd.program_id = v_prog;
    raise notice 'goal %-15s -> reps %-6s rest %ss',
      v_goal, v_min||'-'||v_maxset, v_above;
    if v_min < 1 or v_maxset > 20 then
      raise notice 'FAIL goal % — implausible rep range %-%', v_goal, v_min, v_maxset;
      v_fail := v_fail + 1;
    end if;
  end loop;

  raise notice '─────────────────────────────────────────────';
  raise notice 'swept % plan shapes, % failures', v_runs, v_fail;
  if v_fail > 0 then
    raise exception 'GENERATOR SWEEP: % of % shapes are broken', v_fail, v_runs;
  end if;
  raise notice 'GENERATOR SWEEP: every shape produces a coherent plan';
end $$;
rollback to savepoint sweep;
