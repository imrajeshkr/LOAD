-- A promotion moves the weekly budget from 9 sets/muscle to 14. That lands
-- over two weeks, not in one session.
savepoint ramp;
DO $$
declare v_uid uuid; v_prog uuid; v_pd uuid; v_full int; v_ramped int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,2,3,4,5,6,7]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);
  select id into v_pd from program_days where program_id=v_prog order by ordinal limit 1;
  update scheduled_workouts set program_day_id=v_pd
   where user_id=v_uid and scheduled_for=user_today(v_uid);

  update programs set volume_ramp_until = null where id = v_prog;
  select sum((x->>'sets_target')::int) into v_full
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x;

  update programs set volume_ramp_until = current_date + 7 where id = v_prog;
  select sum((x->>'sets_target')::int) into v_ramped
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x;

  if v_ramped >= v_full then
    raise exception 'ramp did not reduce volume (% vs %)', v_ramped, v_full;
  end if;
  raise notice 'first week after a volume increase: % sets instead of %', v_ramped, v_full;

  -- It expires by itself; nothing has to clean it up.
  update programs set volume_ramp_until = current_date - 1 where id = v_prog;
  select sum((x->>'sets_target')::int) into v_ramped
    from jsonb_array_elements(train_screen(v_uid)->'exercises') x;
  if v_ramped <> v_full then
    raise exception 'ramp did not expire (% vs %)', v_ramped, v_full;
  end if;
  raise notice 'once the date passes: back to % sets', v_ramped;
  raise notice 'V2_0040 RAMP OK';
end $$;
rollback to savepoint ramp;
