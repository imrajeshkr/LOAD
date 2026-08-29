savepoint scope;
DO $$
declare v_uid uuid; v_bench uuid; v_alt uuid; v_prog uuid;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  delete from exercise_swaps where user_id = v_uid;
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  select id into v_bench from exercises where slug='bench-press' and owner_id is null;
  select exercise_id into v_alt from swap_candidates(v_bench) where is_core limit 1;

  -- A standing swap still survives a rebuild.
  perform swap_exercise(v_bench, v_alt, null);
  v_prog := bootstrap_user_program(v_uid);
  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'standing swap did not survive a rebuild';
  end if;
  raise notice 'standing swap  -> survives rebuild';

  -- One expiring yesterday must not be reapplied.
  update exercise_swaps set expires_on = current_date - 1
   where user_id=v_uid and from_exercise_id=v_bench;
  v_prog := bootstrap_user_program(v_uid);
  if not exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                  where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'an expired swap was still applied';
  end if;
  raise notice 'expired swap   -> not reapplied, original lift back';

  -- One expiring today still applies today.
  perform swap_exercise(v_bench, v_alt, current_date);
  v_prog := bootstrap_user_program(v_uid);
  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'a swap expiring today was dropped too early';
  end if;
  raise notice 'today-only swap -> applies today';
  raise notice 'V2_0052 SWAP SCOPE: PASS';
end $$;
rollback to savepoint scope;
