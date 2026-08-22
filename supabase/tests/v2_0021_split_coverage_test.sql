-- Every split must produce a week that trains push, pull AND legs muscles.
-- Fails today for upper_lower (no pull) and full_body (no legs).
DO $$
declare
  v_uid  uuid;
  v_prog uuid;
  v_pats text;
  v_split text;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid)::text, true);

  foreach v_split in array array['push_pull_legs','upper_lower','full_body'] loop
    update training_profiles
       set split_preference = v_split::split_type,
           training_weekdays = array[1,3,5]::smallint[]
     where user_id = v_uid and valid_to is null;

    v_prog := bootstrap_user_program(v_uid);

    select string_agg(distinct e.pattern, ',' order by e.pattern)
      into v_pats
      from program_days pd
      join program_day_exercises pde on pde.program_day_id = pd.id
      join exercises e on e.id = pde.exercise_id
     where pd.program_id = v_prog;

    raise notice '% -> patterns: %', v_split, v_pats;

    if v_pats is null or v_pats not like '%push%' then
      raise exception 'SPLIT % MISSING PUSH (got %)', v_split, v_pats;
    end if;
    if v_pats not like '%pull%' then
      raise exception 'SPLIT % MISSING PULL (got %)', v_split, v_pats;
    end if;
    if v_pats not like '%legs%' then
      raise exception 'SPLIT % MISSING LEGS (got %)', v_split, v_pats;
    end if;
  end loop;

  raise notice 'ALL SPLITS COVER PUSH/PULL/LEGS';
end $$;
