-- Finishing onboarding twice must work. The first attempt used to lock the
-- account out of the app permanently.
savepoint intake;
DO $$
declare
  -- Chosen at run time. This used to hardcode the uuid of the account that
  -- was locked out, which broke the moment that account was deleted and
  -- recreated — a test should not depend on one row surviving.
  v_uid uuid;
  v_payload jsonb;
  v_prog uuid; v_cur int; v_hist int; v_con int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  v_payload := jsonb_build_object(
    'goal','build_muscle', 'goals', jsonb_build_array('build_muscle'),
    'goal_is_coach_choice', false, 'target_direction','gain',
    'target_weight_kg', 73, 'training_weekdays', jsonb_build_array(1,2,4,5),
    'days_per_week', 4, 'split_preference','push_pull_legs',
    'experience','beginner', 'environment','commercial_gym',
    'bar_weight_kg', 20, 'has_benched', false, 'protein_g', 124,
    'constraints', jsonb_build_array(jsonb_build_object('label','left knee','severity','mild')));

  -- ── 1 · First run on an account that ALREADY has a current profile ──────
  perform submit_intake(v_payload);
  select count(*) into v_cur from training_profiles where user_id=v_uid and valid_to is null;
  if v_cur <> 1 then raise exception 'expected exactly 1 current profile, got %', v_cur; end if;
  raise notice 'run 1 on a locked account -> ok, 1 current profile';

  -- ── 2 · And again. This is what used to fail with 23505 ─────────────────
  perform submit_intake(v_payload);
  select count(*) into v_cur  from training_profiles where user_id=v_uid and valid_to is null;
  select count(*) into v_hist from training_profiles where user_id=v_uid and valid_to is not null;
  if v_cur <> 1 then raise exception 'second run left % current profiles', v_cur; end if;
  if v_hist < 2 then raise exception 'superseded rows were not kept (% found)', v_hist; end if;
  raise notice 'run 2                     -> ok, 1 current + % superseded', v_hist;

  -- ── 3 · Injuries replaced, not stacked ──────────────────────────────────
  select count(*) into v_con from user_constraints where user_id=v_uid and active_to is null;
  if v_con <> 1 then raise exception 'injury flags stacked: % active', v_con; end if;
  raise notice 'injury flags              -> replaced, not stacked (%)', v_con;

  -- ── 4 · Nutrition target also single-current ────────────────────────────
  select count(*) into v_cur from nutrition_targets where user_id=v_uid and valid_to is null;
  if v_cur <> 1 then raise exception '% current nutrition targets', v_cur; end if;

  -- ── 5 · And the plan actually builds, which is the whole point ──────────
  v_prog := bootstrap_user_program(v_uid);
  if v_prog is null then raise exception 'plan still did not build'; end if;
  if not exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                  where pd.program_id=v_prog) then
    raise exception 'program built but has no exercises';
  end if;
  raise notice 'plan built                -> % days',
    (select count(*) from program_days where program_id=v_prog);

  raise notice 'V2_0047 INTAKE IDEMPOTENT: PASS';
end $$;
rollback to savepoint intake;
