-- The point of v2_0031: a client that omits the intake keys entirely — which
-- is exactly what a pre-Plan-01 build does — must still land a usable row.
savepoint defs;
DO $$
declare v_uid uuid; v_exp text; v_env text;
begin
  select id into v_uid from profiles order by created_at limit 1;
  update training_profiles set valid_to = now()
   where user_id = v_uid and valid_to is null;

  -- Simulates the old payload: no experience, no environment.
  insert into training_profiles (user_id, goal, goals, split_preference, days_per_week)
  values (v_uid, 'build_muscle', array['build_muscle']::training_goal[],
          'push_pull_legs', 4);

  select experience::text, environment::text into v_exp, v_env
    from training_profiles where user_id = v_uid and valid_to is null;

  if v_exp is null or v_env is null then
    raise exception 'old-client insert still lands NULL (exp=%, env=%)', v_exp, v_env;
  end if;
  raise notice 'old-client payload -> experience=%, environment=%', v_exp, v_env;
  raise notice 'V2_0031 DEFAULTS OK';
end $$;
rollback to savepoint defs;
