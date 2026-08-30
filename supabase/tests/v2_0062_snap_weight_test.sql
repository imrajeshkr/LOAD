-- No lifter can load 8.8 kg on a dumbbell. Every prescribed weight must be a
-- real increment, and must survive the trigger regardless of who wrote it.
savepoint t;
DO $$
declare
  v_uid  uuid;
  v_prog uuid;
  v_db   uuid;
  v_bb   uuid;
  v_bad  int;
  v_got  numeric;
  v_day  uuid;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  select id into v_db from exercises where slug = 'db-bench-press';
  select id into v_bb from exercises where slug = 'back-squat';

  -- The exact numbers from the report.
  if snap_weight(v_uid, v_db, 8.8) not in (8, 10) then
    raise exception 'FAIL: a dumbbell press snapped to %', snap_weight(v_uid, v_db, 8.8);
  end if;
  v_got := snap_weight(v_uid, v_db, 8.8);
  if (v_got * 2) <> round(v_got * 2) then
    raise exception 'FAIL: % is not on a half-kilo grid', v_got;
  end if;

  -- The bug that would have handed a dumbbell lifter a barbell's weight.
  if snap_weight(v_uid, v_db, 8.8) >= 20 then
    raise exception 'FAIL: a light dumbbell was snapped up to bar weight';
  end if;

  -- Bars still get plate maths.
  v_got := snap_weight(v_uid, v_bb, 47.3);
  if (v_got * 2) <> round(v_got * 2) then
    raise exception 'FAIL: barbell snap gave %', v_got;
  end if;

  -- Never below one increment.
  if snap_weight(v_uid, v_db, 0.4) <= 0 then
    raise exception 'FAIL: snapped a real lift to nothing';
  end if;

  -- And the trigger holds the line whatever the generator writes.
  v_prog := bootstrap_user_program(v_uid);
  select pd.id into v_day from program_days pd where pd.program_id = v_prog limit 1;
  update program_day_exercises set target_weight_kg = 8.8
   where program_day_id = v_day and exercise_id in (
     select exercise_id from program_day_exercises where program_day_id = v_day limit 1);

  select count(*) into v_bad
    from program_day_exercises pde
    join program_days pd on pd.id = pde.program_day_id
   where pd.program_id = v_prog
     and pde.target_weight_kg is not null
     and (pde.target_weight_kg * 2) <> round(pde.target_weight_kg * 2);
  if v_bad > 0 then
    raise exception 'FAIL: % prescribed weights are off the half-kilo grid', v_bad;
  end if;

  raise notice 'SNAP WEIGHT: every prescribed weight is one you can pick up';
end $$;
rollback to savepoint t;
