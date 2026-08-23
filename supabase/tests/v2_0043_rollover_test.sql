-- §8.4 block end and §13.8 returning. Both rebuild and both open light; only
-- the wording differs, and neither ever says "deload".
savepoint roll;
DO $$
declare v_uid uuid; v_prog uuid; v_r text; v_ramp date; v_body text; v_ws uuid;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  delete from workout_sessions where user_id=v_uid;
  delete from training_pauses  where user_id=v_uid;
  delete from coach_messages   where user_id=v_uid and category='plan_updated';
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  -- ── 1 · Mid-block, trained recently: nothing happens ────────────────────
  insert into workout_sessions (user_id,title,performed_on,status,started_at,completed_at)
  values (v_uid,'r',user_today(v_uid)-1,'completed',
          now()-interval '1 day', now()-interval '1 day') returning id into v_ws;
  v_r := roll_block_if_due(v_uid);
  if v_r is not null then raise exception 'rolled mid-block: %', v_r; end if;
  raise notice 'mid-block, training     -> nothing';

  -- ── 2 · Block end: rebuild + light week ─────────────────────────────────
  -- programs_check requires ends_on >= starts_on, so age the whole block
  -- rather than just its end — which is also what a real 6-week block looks
  -- like on the day it expires.
  update programs set starts_on = user_today(v_uid) - 43,
                      ends_on   = user_today(v_uid) - 1
   where id = v_prog;
  v_r := roll_block_if_due(v_uid);
  if v_r is distinct from 'block_end' then raise exception 'expected block_end, got %', v_r; end if;
  select volume_ramp_until into v_ramp from programs
   where user_id=v_uid and status='active';
  if v_ramp is null or v_ramp <= user_today(v_uid) then
    raise exception 'block rolled without a lighter week (ramp=%)', v_ramp;
  end if;
  select content into v_body from coach_messages
   where user_id=v_uid and category='plan_updated' order by created_at desc limit 1;
  raise notice 'block end               -> rebuilt, light until %', v_ramp;
  raise notice '    "%"', v_body;
  if v_body ilike '%deload%' then raise exception 'the word "deload" leaked'; end if;

  -- ── 3 · Silent absence of 4 weeks: asks nothing, just eases in ──────────
  delete from workout_sessions where user_id=v_uid;
  delete from coach_messages where user_id=v_uid and category='plan_updated';
  insert into workout_sessions (user_id,title,performed_on,status,started_at,completed_at)
  values (v_uid,'r',user_today(v_uid)-28,'completed',
          now()-interval '28 days', now()-interval '28 days');
  update programs set volume_ramp_until=null, ends_on=user_today(v_uid)+30
   where user_id=v_uid and status='active';
  raise notice '  (layoff_days=%, paused=%)', layoff_days(v_uid), is_training_paused(v_uid);
  v_r := roll_block_if_due(v_uid);
  if v_r is distinct from 'returning_silent' then
    raise exception 'expected returning_silent, got % (layoff=%)', v_r, layoff_days(v_uid);
  end if;
  select content into v_body from coach_messages
   where user_id=v_uid and category='plan_updated' order by created_at desc limit 1;
  raise notice 'silent 4 weeks          -> %', v_r;
  raise notice '    "%"', v_body;

  -- ── 4 · A declared pause gets the warmer wording, no questions ──────────
  delete from workout_sessions where user_id=v_uid;
  delete from coach_messages where user_id=v_uid and category='plan_updated';
  insert into workout_sessions (user_id,title,performed_on,status,started_at,completed_at)
  values (v_uid,'r',user_today(v_uid)-20,'completed',
          now()-interval '20 days', now()-interval '20 days');
  insert into training_pauses (user_id, started_on, ended_on)
  values (v_uid, user_today(v_uid)-19, user_today(v_uid)-1);
  update programs set volume_ramp_until=null where user_id=v_uid and status='active';
  v_r := roll_block_if_due(v_uid);
  if v_r is distinct from 'returning_declared' then
    raise exception 'expected returning_declared, got %', v_r;
  end if;
  select content into v_body from coach_messages
   where user_id=v_uid and category='plan_updated' order by created_at desc limit 1;
  raise notice 'declared pause          -> %', v_r;
  raise notice '    "%"', v_body;

  -- ── 5 · Nothing rolls while still paused ────────────────────────────────
  insert into training_pauses (user_id, started_on) values (v_uid, user_today(v_uid));
  if roll_block_if_due(v_uid) is not null then
    raise exception 'rolled the plan while training was paused';
  end if;
  raise notice 'while paused            -> nothing';

  raise notice 'V2_0043 ROLLOVER: PASS';
end $$;
rollback to savepoint roll;
