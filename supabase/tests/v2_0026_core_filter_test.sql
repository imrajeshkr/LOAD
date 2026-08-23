savepoint core_filter_test;
DO $$
declare
  v_uid uuid; v_prog uuid; v_ext int; v_above int; v_tot int;
begin
  select tp.user_id into v_uid from training_profiles tp
   where tp.valid_to is null and tp.experience='beginner' limit 1;
  if v_uid is null then select id into v_uid from profiles limit 1; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  v_prog := bootstrap_user_program(v_uid);

  select count(*) into v_tot from program_days pd
    join program_day_exercises pde on pde.program_day_id=pd.id where pd.program_id=v_prog;

  -- Nothing Extended may be prescribed BY THE GENERATOR. A lift the lifter
  -- swapped in themselves is a different matter: spec §9 offers Extended
  -- candidates deliberately, and since v2_0033 gave the whole catalog joint
  -- data they are vetted against injuries like anything else. So exclude
  -- exercises that arrived through a standing swap — this test predates the
  -- swap feature and used to fail the moment anyone used it.
  select count(*) into v_ext from program_days pd
    join program_day_exercises pde on pde.program_day_id=pd.id
    join exercises e on e.id=pde.exercise_id
   where pd.program_id=v_prog and not e.is_core
     and not exists (select 1 from exercise_swaps s
                      where s.user_id=v_uid and s.to_exercise_id=e.id);

  -- nothing above the lifter's training age
  select count(*) into v_above from program_days pd
    join program_day_exercises pde on pde.program_day_id=pd.id
    join exercises e on e.id=pde.exercise_id
   where pd.program_id=v_prog
     and e.min_experience > coalesce((select experience from training_profiles
                                       where user_id=v_uid and valid_to is null),'intermediate');

  raise notice 'prescribed=%  extended=%  above-level=%', v_tot, v_ext, v_above;
  if v_ext   > 0 then raise exception 'EXTENDED ROWS PRESCRIBED: %', v_ext; end if;
  if v_above > 0 then raise exception 'ABOVE-LEVEL LIFTS PRESCRIBED: %', v_above; end if;
  if v_tot   = 0 then raise exception 'NOTHING PRESCRIBED AT ALL'; end if;
  raise notice 'CORE + LEVEL FILTERS OK';
end $$;
rollback to savepoint core_filter_test;
