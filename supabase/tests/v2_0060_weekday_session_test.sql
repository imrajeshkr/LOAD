-- set_weekday_session rewrites every future instance of one weekday, and
-- leaves the other weekdays and the past alone.
savepoint t;
DO $$
declare
  v_uid    uuid;
  v_prog   uuid;
  v_pd     uuid;
  v_wd     smallint;
  v_future int;
  v_wrong  int;
  v_others_before int;
  v_others_after  int;
  v_first  date;
  v_seed   uuid;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  v_prog := bootstrap_user_program(v_uid);
  -- Bootstrap only materialises the near term; the point of this test is the
  -- rewrite across many future weeks, so fill the calendar out first.
  perform ensure_my_schedule();

  -- The rewrite must hit EVERY future instance of the weekday, so the test
  -- needs at least two. A two-week window on an every-other-day schedule has
  -- each weekday exactly once, so a second instance is planted a week on.
  select scheduled_for into v_first from scheduled_workouts
   where user_id = v_uid and scheduled_for > user_today(v_uid)
   order by scheduled_for limit 1;
  if v_first is null then raise exception 'FAIL: no future rows to test with'; end if;
  v_wd := extract(isodow from v_first)::smallint;

  select id into v_seed from program_days where program_id = v_prog order by ordinal desc limit 1;
  insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
  values (v_uid, v_prog, v_seed, v_first + 7)
  on conflict do nothing;

  select id into v_pd from program_days where program_id = v_prog order by ordinal limit 1;

  select count(*) into v_others_before from scheduled_workouts
   where user_id = v_uid and scheduled_for >= user_today(v_uid)
     and extract(isodow from scheduled_for)::smallint <> v_wd;

  perform set_weekday_session(v_wd, v_pd);

  select count(*) into v_wrong from scheduled_workouts
   where user_id = v_uid and scheduled_for > user_today(v_uid)
     and extract(isodow from scheduled_for)::smallint = v_wd
     and program_day_id is distinct from v_pd;
  if v_wrong > 0 then
    raise exception 'FAIL: % future rows on that weekday were not rewritten', v_wrong;
  end if;

  select count(*) into v_others_after from scheduled_workouts
   where user_id = v_uid and scheduled_for >= user_today(v_uid)
     and extract(isodow from scheduled_for)::smallint <> v_wd;
  if v_others_after <> v_others_before then
    raise exception 'FAIL: other weekdays changed (% -> %)', v_others_before, v_others_after;
  end if;

  -- Rest clears every future instance of that weekday.
  perform set_weekday_session(v_wd, null);
  select count(*) into v_future from scheduled_workouts
   where user_id = v_uid and scheduled_for > user_today(v_uid)
     and extract(isodow from scheduled_for)::smallint = v_wd;
  if v_future > 0 then
    raise exception 'FAIL: % rows survived being set to rest', v_future;
  end if;

  raise notice 'SET WEEKDAY SESSION: the weekday changes, nothing else does';
end $$;
rollback to savepoint t;
