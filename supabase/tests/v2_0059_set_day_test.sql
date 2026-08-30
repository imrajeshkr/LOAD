-- set_day_session changes one day and leaves the rest of the week alone.
savepoint t;
DO $$
declare
  v_uid   uuid;
  v_prog  uuid;
  v_legs  uuid;
  v_date  date;
  v_other date;
  v_other_pd_before uuid;
  v_other_pd_after  uuid;
  v_got   uuid;
  v_days  int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  v_prog := bootstrap_user_program(v_uid);

  select count(*) into v_days from my_program_days();
  if v_days = 0 then raise exception 'FAIL: my_program_days returned nothing'; end if;

  -- Two future days that both hold a session.
  select scheduled_for into v_date from scheduled_workouts
   where user_id = v_uid and scheduled_for > user_today(v_uid)
     and program_day_id is not null order by scheduled_for limit 1;
  select scheduled_for into v_other from scheduled_workouts
   where user_id = v_uid and scheduled_for > v_date
     and program_day_id is not null order by scheduled_for limit 1;
  if v_date is null or v_other is null then
    raise exception 'FAIL: need two future training days to test with';
  end if;
  select program_day_id into v_other_pd_before
    from scheduled_workouts where user_id = v_uid and scheduled_for = v_other;

  -- Pick a program day that is NOT what v_date already holds.
  select pd.id into v_legs from program_days pd
   where pd.program_id = v_prog
     and pd.id is distinct from (select program_day_id from scheduled_workouts
                                  where user_id = v_uid and scheduled_for = v_date)
   limit 1;

  perform set_day_session(v_date, v_legs);

  select program_day_id into v_got from scheduled_workouts
   where user_id = v_uid and scheduled_for = v_date;
  if v_got is distinct from v_legs then
    raise exception 'FAIL: the day did not take the new session';
  end if;

  -- The whole point: nothing else moved.
  select program_day_id into v_other_pd_after
    from scheduled_workouts where user_id = v_uid and scheduled_for = v_other;
  if v_other_pd_after is distinct from v_other_pd_before then
    raise exception 'FAIL: changing one day disturbed another';
  end if;

  -- Rest clears the day outright rather than relocating the session.
  perform set_day_session(v_date, null);
  if exists (select 1 from scheduled_workouts
              where user_id = v_uid and scheduled_for = v_date) then
    raise exception 'FAIL: rest did not clear the day';
  end if;

  -- The past stays the past.
  begin
    perform set_day_session(user_today(v_uid) - 1, v_legs);
    raise exception 'FAIL: editing a past day was allowed';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  raise notice 'SET DAY SESSION: one day changes, the week does not';
end $$;
rollback to savepoint t;
