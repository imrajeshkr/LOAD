-- The trigger must fire on finish, and must never be able to block a session
-- from being completed.
savepoint trg;
DO $$
declare v_uid uuid; v_ws uuid; v_before int; v_after int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  -- workout_sessions_one_open_uq allows a single open session per user.
  delete from workout_sessions where user_id=v_uid and status <> 'completed';

  select count(*) into v_before from coach_proposals
   where user_id=v_uid and kind='level_change';

  insert into workout_sessions (user_id, title, performed_on, status, started_at)
  values (v_uid, 'trigger probe', user_today(v_uid), 'in_progress', now())
  returning id into v_ws;

  update workout_sessions set status='completed', completed_at=now() where id=v_ws;

  if not exists (select 1 from workout_sessions
                  where id=v_ws and status='completed') then
    raise exception 'the trigger blocked session completion';
  end if;

  select count(*) into v_after from coach_proposals
   where user_id=v_uid and kind='level_change';
  raise notice 'session completed cleanly; level proposals %  -> %', v_before, v_after;
  raise notice 'V2_0039 TRIGGER OK';
end $$;
rollback to savepoint trg;
