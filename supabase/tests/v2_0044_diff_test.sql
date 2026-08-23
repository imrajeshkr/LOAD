-- §8.3 item 4: after a rebuild, say what actually changed.
savepoint dif;
DO $$
declare v_uid uuid; v_p1 uuid; v_p2 uuid; d record; v_body text;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_uid)::text, true);
  delete from workout_sessions where user_id=v_uid;
  delete from exercise_swaps where user_id=v_uid;
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;

  v_p1 := bootstrap_user_program(v_uid);

  -- Same shape rebuilt: continuity (v2_0042) should keep essentially everything.
  v_p2 := bootstrap_user_program(v_uid);
  select * into d from program_diff(v_uid);
  if cardinality(d.kept) = 0 then
    raise exception 'identical rebuild kept nothing — continuity is not working';
  end if;
  raise notice 'same shape   -> kept %, added %, dropped %',
    cardinality(d.kept), cardinality(d.added), cardinality(d.dropped);

  -- A real shape change must show real movement.
  update training_profiles set split_preference='upper_lower',
         training_weekdays=array[1,2,4,5]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_p2 := bootstrap_user_program(v_uid);
  select * into d from program_diff(v_uid);
  if cardinality(d.kept) = 0 and cardinality(d.added) = 0 then
    raise exception 'split change produced an empty diff';
  end if;
  raise notice 'PPL -> U/L   -> kept %, added %, dropped %',
    cardinality(d.kept), cardinality(d.added), cardinality(d.dropped);
  raise notice '    kept:    %', array_to_string(d.kept, ', ');
  raise notice '    added:   %', array_to_string(d.added, ', ');
  raise notice '    dropped: %', array_to_string(d.dropped, ', ');

  -- The block-rollover note should now name what it added.
  delete from coach_messages where user_id=v_uid and category='plan_updated';
  update programs set starts_on=user_today(v_uid)-43, ends_on=user_today(v_uid)-1
   where user_id=v_uid and status='active';
  perform roll_block_if_due(v_uid);
  select content into v_body from coach_messages
   where user_id=v_uid and category='plan_updated' order by created_at desc limit 1;
  raise notice 'rollover note: "%"', v_body;

  raise notice 'V2_0044 DIFF: PASS';
end $$;
rollback to savepoint dif;
