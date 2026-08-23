-- §8.3 continuity and §8.4 blocks.
--
-- A rebuild must not take away the compound you are mid-progress on, must
-- rotate accessories you have been doing, and must give non-beginners a block
-- end date.

savepoint cont;

create or replace function _seed1(p_uid uuid, p_ex uuid, p_days int[])
returns void language plpgsql as $$
declare v_ws uuid; v_se uuid; d int;
begin
  foreach d in array p_days loop
    insert into workout_sessions (user_id, title, performed_on, status, started_at, completed_at)
    values (p_uid, 'seedc', user_today(p_uid) - d, 'completed',
            now() - (d||' days')::interval, now() - (d||' days')::interval + interval '1 hour')
    returning id into v_ws;
    insert into session_exercises (user_id, session_id, exercise_id, ordinal)
    values (p_uid, v_ws, p_ex, 1) returning id into v_se;
    insert into session_sets (user_id, session_exercise_id, set_number,
                              weight_kg, reps, rir, is_completed, kind)
    values (p_uid, v_se, 1, 50, 8, 2, true, 'working');
  end loop;
end $$;

DO $$
declare
  v_uid uuid; v_prog uuid; v_ends date;
  v_compound uuid; v_iso uuid; v_name text;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  delete from workout_sessions where user_id = v_uid;
  delete from exercise_swaps  where user_id = v_uid;

  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[],
         goals=array['build_muscle']::training_goal[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  -- ── 1 · Blocks (§8.4) ────────────────────────────────────────────────────
  select ends_on into v_ends from programs where id = v_prog;
  if v_ends is null then raise exception 'intermediate program has no block end'; end if;
  if v_ends <> current_date + 42 then
    raise exception 'intermediate block should be 6 weeks, ends_on = %', v_ends;
  end if;
  raise notice 'intermediate block ends % (6 weeks)', v_ends;

  update training_profiles set experience='beginner' where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);
  select ends_on into v_ends from programs where id = v_prog;
  if v_ends is not null then
    raise exception 'beginner should have no block end, got %', v_ends;
  end if;
  raise notice 'beginner block          -> none, as intended';

  update training_profiles set experience='advanced' where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);
  select ends_on into v_ends from programs where id = v_prog;
  if v_ends <> current_date + 28 then
    raise exception 'advanced block should be 4 weeks, ends_on = %', v_ends;
  end if;
  raise notice 'advanced block ends % (4 weeks)', v_ends;

  -- ── 2 · Continuity: a trained compound keeps its slot (§8.3) ─────────────
  update training_profiles set experience='intermediate' where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  -- Pick a compound the plan did NOT choose, then train it for three weeks.
  select e.id into v_compound
    from exercises e
    join exercise_muscles em on em.exercise_id=e.id and em.role='primary'
    join muscles m on m.id=em.muscle_id
   where e.owner_id is null and e.is_core and e.mechanic='compound'
     and m.name='Chest' and e.min_experience <= 'intermediate'
     and e.id not in (select pde.exercise_id from program_day_exercises pde
                        join program_days pd on pd.id=pde.program_day_id
                       where pd.program_id=v_prog)
   limit 1;
  if v_compound is null then raise exception 'no unused chest compound to test with'; end if;

  perform _seed1(v_uid, v_compound, array[3,6,9,12]);
  v_prog := bootstrap_user_program(v_uid);

  if not exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                  where pd.program_id=v_prog and pde.exercise_id=v_compound) then
    select name into v_name from exercises where id=v_compound;
    raise exception 'rebuild dropped %, a compound trained for three weeks', v_name;
  end if;
  select name into v_name from exercises where id=v_compound;
  raise notice 'continuity              -> % kept after a rebuild', v_name;

  -- ── 3 · Variation: a trained accessory gives its slot up (§8.4) ─────────
  select pde.exercise_id into v_iso
    from program_day_exercises pde
    join program_days pd on pd.id=pde.program_day_id
    join exercises e on e.id=pde.exercise_id
   where pd.program_id=v_prog and e.mechanic='isolation'
     and (select count(*) from exercises e2
            join exercise_muscles em2 on em2.exercise_id=e2.id and em2.role='primary'
           where e2.owner_id is null and e2.is_core and e2.mechanic='isolation'
             and em2.muscle_id in (select muscle_id from exercise_muscles
                                    where exercise_id=e.id and role='primary')) > 1
   limit 1;

  if v_iso is not null then
    perform _seed1(v_uid, v_iso, array[2,5,8]);
    v_prog := bootstrap_user_program(v_uid);
    select name into v_name from exercises where id=v_iso;
    if exists (select 1 from program_day_exercises pde
                 join program_days pd on pd.id=pde.program_day_id
                where pd.program_id=v_prog and pde.exercise_id=v_iso) then
      raise exception 'accessory % was kept; it should have rotated out', v_name;
    end if;
    raise notice 'variation               -> % rotated out for something new', v_name;
  else
    raise notice 'variation               -> skipped, no muscle has a spare accessory';
  end if;

  raise notice 'V2_0042 CONTINUITY + BLOCKS: PASS';
end $$;
rollback to savepoint cont;
