savepoint bw_plan;
DO $$
declare v_uid uuid; v_prog uuid; v_empty int; v_min int; v_tot int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  update training_profiles set environment='bodyweight_only', split_preference='full_body',
         training_weekdays=array[1,3,5]::smallint[], experience='beginner'
   where user_id=v_uid and valid_to is null;

  v_prog := bootstrap_user_program(v_uid);

  select count(*) into v_tot from program_days pd
    join program_day_exercises pde on pde.program_day_id=pd.id where pd.program_id=v_prog;
  select count(*) into v_empty from program_days pd
   where pd.program_id=v_prog
     and not exists (select 1 from program_day_exercises x where x.program_day_id=pd.id);
  select min(c) into v_min from (
    select count(pde.*) as c from program_days pd
      left join program_day_exercises pde on pde.program_day_id=pd.id
     where pd.program_id=v_prog group by pd.id) s;

  raise notice 'bodyweight_only full_body: total=%  empty days=%  smallest day=%', v_tot, v_empty, v_min;
  if v_empty > 0 then raise exception 'STILL GENERATING EMPTY DAYS: %', v_empty; end if;
  if v_min < 2 then raise exception 'A DAY HAS ONLY % EXERCISE(S)', v_min; end if;
  raise notice 'BODYWEIGHT PLAN IS VIABLE';
end $$;
rollback to savepoint bw_plan;
