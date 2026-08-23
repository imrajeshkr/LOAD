-- §8.3 item 3: a structural change that raises weekly volume opens light.
savepoint sr;
DO $$
declare v_uid uuid; v_p uuid; v_ramp date; v_small int; v_big int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  delete from workout_sessions where user_id=v_uid;

  -- Start small: 3 days.
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[], goals=array['build_muscle']::training_goal[]
   where user_id=v_uid and valid_to is null;
  v_p := bootstrap_user_program(v_uid);
  select sum(pde.sets_target) into v_small from program_day_exercises pde
    join program_days pd on pd.id=pde.program_day_id where pd.program_id=v_p;
  raise notice '3-day week: % sets', v_small;

  -- Same shape again: no ramp, nothing got bigger.
  v_p := bootstrap_user_program(v_uid);
  select volume_ramp_until into v_ramp from programs where id=v_p;
  if v_ramp is not null then raise exception 'ramped on an unchanged week'; end if;
  raise notice 'rebuild, same shape -> no ramp';

  -- Now double the week.
  update training_profiles set training_weekdays=array[1,2,3,4,5,6]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_p := bootstrap_user_program(v_uid);
  select sum(pde.sets_target) into v_big from program_day_exercises pde
    join program_days pd on pd.id=pde.program_day_id where pd.program_id=v_p;
  select volume_ramp_until into v_ramp from programs where id=v_p;
  raise notice '6-day week: % sets (was %)', v_big, v_small;
  if v_ramp is null then
    raise exception '% -> % sets with no ramp', v_small, v_big;
  end if;
  raise notice '3 days -> 6 days      -> opens light until %', v_ramp;

  -- And shrinking back must not ramp.
  update training_profiles set training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_p := bootstrap_user_program(v_uid);
  select volume_ramp_until into v_ramp from programs where id=v_p;
  if v_ramp is not null then raise exception 'ramped while cutting volume'; end if;
  raise notice '6 days -> 3 days      -> no ramp, week got smaller';

  raise notice 'V2_0049 SHAPE RAMP: PASS';
end $$;
rollback to savepoint sr;
