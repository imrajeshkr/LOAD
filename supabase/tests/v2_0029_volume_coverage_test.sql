-- Plan 03 acceptance test (spec §14): "side delt, rear delt and calves receive
-- their weekly volume target under every split". Abs are included because
-- v2_0029 is the first version in which any split trains them at all.
--
-- Also asserts that `goal` now changes the prescription — build_muscle and
-- strength produced byte-identical plans before this migration.

savepoint vol_cov;
DO $$
declare
  v_uid    uuid;
  v_prog   uuid;
  v_split  text;
  v_splits text[] := array['push_pull_legs','upper_lower','full_body'];
  v_days   smallint[];
  v_miss   text;
  v_empty  int;
  v_rec    record;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  foreach v_split in array v_splits loop
    -- Day counts that make each split repeat its cycle, which is exactly the
    -- case the old generator collapsed into duplicate sessions.
    v_days := case v_split
                when 'push_pull_legs' then array[1,2,3,4,5,6]::smallint[]
                when 'upper_lower'    then array[1,2,4,5]::smallint[]
                else                       array[1,3,5]::smallint[]
              end;

    update training_profiles
       set split_preference = v_split::split_type,
           training_weekdays = v_days,
           experience = 'intermediate',
           environment = 'commercial_gym',
           goals = array['build_muscle']::training_goal[]
     where user_id = v_uid and valid_to is null;

    v_prog := bootstrap_user_program(v_uid);

    select count(*) into v_empty from program_days pd
     where pd.program_id = v_prog
       and not exists (select 1 from program_day_exercises x
                        where x.program_day_id = pd.id);
    if v_empty > 0 then
      raise exception '% : % empty day(s)', v_split, v_empty;
    end if;

    -- The muscles that lost the slot race under every previous generator.
    select string_agg(m.name, ', ' order by m.name) into v_miss
      from muscles m
     where m.name in ('Side Delt','Rear Delt','Calves','Abs')
       and not exists (
             select 1
               from program_day_exercises pde
               join program_days pd on pd.id = pde.program_day_id
               join exercise_muscles em on em.exercise_id = pde.exercise_id
                                       and em.role = 'primary'
              where pd.program_id = v_prog and em.muscle_id = m.id);

    if v_miss is not null then
      raise exception '% : NO WEEKLY VOLUME for %', v_split, v_miss;
    end if;

    raise notice '% (% days): all of Side Delt / Rear Delt / Calves / Abs trained',
      v_split, cardinality(v_days);

    for v_rec in
      select pd.label, count(*) as lifts, sum(pde.sets_target) as sets
        from program_days pd
        join program_day_exercises pde on pde.program_day_id = pd.id
       where pd.program_id = v_prog
       group by pd.id, pd.label, pd.ordinal order by pd.ordinal
    loop
      raise notice '    % — % lifts, % sets', v_rec.label, v_rec.lifts, v_rec.sets;
      -- Session length has to stay trainable. Under 8 sets is not a session;
      -- over 24 is the two-hour workout that budget-derived set counts produced.
      if v_rec.sets > 24 or v_rec.sets < 8 then
        raise exception '% : "%" has % sets — outside the trainable 8-24 range',
          v_split, v_rec.label, v_rec.sets;
      end if;
    end loop;
  end loop;

  -- Goal must actually change the prescription.
  update training_profiles set split_preference='push_pull_legs',
         training_weekdays=array[1,3,5]::smallint[],
         goals = array['strength']::training_goal[]
   where user_id = v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  select max(rep_high) into v_empty
    from program_day_exercises pde
    join program_days pd on pd.id = pde.program_day_id
   where pd.program_id = v_prog;
  if v_empty > 6 then
    raise exception 'strength goal still prescribing rep_high=% (expected <= 6)', v_empty;
  end if;
  raise notice 'strength goal: rep_high capped at % ', v_empty;

  raise notice 'PLAN 03 COVERAGE ACCEPTANCE: PASS';
end $$;
rollback to savepoint vol_cov;
