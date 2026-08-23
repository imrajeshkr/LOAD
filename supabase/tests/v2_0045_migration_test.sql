-- §13.1: everyone still on the old generator gets moved across, but never
-- in the middle of a week they have already started.
savepoint mig;
DO $$
declare v_uid uuid; v_prog uuid; v_r text; v_days int; v_abs boolean; v_body text;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_uid)::text, true);
  delete from workout_sessions where user_id=v_uid;
  delete from training_pauses  where user_id=v_uid;
  delete from coach_messages   where user_id=v_uid and category='plan_updated';
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,2,3,4,5,6]::smallint[]
   where user_id=v_uid and valid_to is null;

  v_prog := bootstrap_user_program(v_uid);
  -- Pretend it came from the old generator, as every live program did.
  update programs set generator_version = 1, ends_on = null where id = v_prog;

  -- ── 1 · Week already under way: leave it alone ──────────────────────────
  insert into workout_sessions (user_id,title,performed_on,status,started_at,completed_at)
  values (v_uid,'m',user_today(v_uid),'completed',now(),now());
  v_r := roll_block_if_due(v_uid);
  if v_r is distinct from null then
    raise exception 'rebuilt mid-week (got %)', v_r;
  end if;
  raise notice 'trained this week      -> left alone';

  -- ── 2 · Fresh week: migrate ────────────────────────────────────────────
  delete from workout_sessions where user_id=v_uid;
  v_r := roll_block_if_due(v_uid);
  if v_r is distinct from 'generator_upgrade' then
    raise exception 'expected generator_upgrade, got %', v_r;
  end if;

  select generator_version into v_days from programs
   where user_id=v_uid and status='active';
  if v_days <> 3 then raise exception 'new program still version %', v_days; end if;

  select count(*) into v_days from program_days pd
    join programs p on p.id=pd.program_id
   where p.user_id=v_uid and p.status='active';
  if v_days <> 6 then
    raise exception 'a 6-day lifter should get 6 sessions, got %', v_days;
  end if;

  select exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                   join programs p on p.id=pd.program_id
                   join exercises e on e.id=pde.exercise_id
                  where p.user_id=v_uid and p.status='active' and e.pattern='core')
    into v_abs;
  if not v_abs then raise exception 'migrated plan still trains no abs'; end if;

  raise notice 'fresh week             -> migrated: % sessions, abs trained', v_days;
  select content into v_body from coach_messages
   where user_id=v_uid and category='plan_updated' order by created_at desc limit 1;
  raise notice '    "%"', v_body;
  if v_body ilike '%algorithm%' or v_body ilike '%generator%' or v_body ilike '%version%' then
    raise exception 'the note talks about our internals, not their training';
  end if;

  -- ── 3 · Already migrated: nothing further ──────────────────────────────
  if roll_block_if_due(v_uid) is not null then
    raise exception 'migrated a program that was already current';
  end if;
  raise notice 'already current        -> nothing further';

  raise notice 'V2_0045 MIGRATION: PASS';
end $$;
rollback to savepoint mig;
