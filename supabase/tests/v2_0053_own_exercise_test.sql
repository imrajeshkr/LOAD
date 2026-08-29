savepoint own;
DO $$
declare v_uid uuid; v_mine uuid; v_cat uuid; v_muscle uuid; v_blocked boolean := false;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select id into v_muscle from muscles where name='Chest';
  select id into v_cat from exercises where slug='bench-press' and owner_id is null;

  insert into exercises (slug, name, pattern, load_type, owner_id, is_core, min_experience)
  values ('my-test-lift-'||substr(md5(random()::text),1,6), 'My Test Lift',
          'push', 'weight_reps', v_uid, false, 'beginner')
  returning id into v_mine;

  insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
  values (v_mine, v_muscle, 'primary', 1.0);
  raise notice 'own exercise    -> muscle attached';

  begin
    insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
    values (v_cat, v_muscle, 'secondary', 0.5);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'a lifter attached a muscle to a CATALOGUE exercise';
  end if;
  raise notice 'catalogue lift  -> refused, as it must be';
  raise notice 'V2_0053 OWN EXERCISE DETAILS: PASS';
end $$;
rollback to savepoint own;
