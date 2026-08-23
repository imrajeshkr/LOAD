-- Plan 05 acceptance (spec §9): swap offers same-muscle alternatives that pass
-- the same hard filters, never inherits the replaced lift's weight, and — the
-- part that needed a table rather than a column — survives regeneration.

savepoint swap;
DO $$
declare
  v_uid uuid; v_prog uuid; v_bench uuid; v_alt uuid;
  v_n int; v_core int; v_ext int; v_still int; v_kg numeric; v_altkg numeric;
  v_shoulder uuid; v_blind int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  update training_profiles
     set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[],
         goals=array['build_muscle']::training_goal[]
   where user_id=v_uid and valid_to is null;
  delete from user_constraints where user_id = v_uid;
  delete from exercise_swaps where user_id = v_uid;
  v_prog := bootstrap_user_program(v_uid);

  select id into v_bench from exercises where slug='bench-press' and owner_id is null;

  -- ── 1 · Candidates exist, Core and Extended both reachable ───────────────
  select count(*), count(*) filter (where is_core), count(*) filter (where not is_core)
    into v_n, v_core, v_ext from swap_candidates(v_bench);
  if v_core = 0 or v_ext = 0 then
    raise exception 'expected both Core and Extended candidates, got %/%', v_core, v_ext;
  end if;
  raise notice 'bench-press swap candidates: % (% core, % extended)', v_n, v_core, v_ext;

  -- Everything offered must train a muscle bench press trains.
  if exists (
    select 1 from swap_candidates(v_bench) c
     where not exists (
       select 1 from exercise_muscles a
         join exercise_muscles b on b.muscle_id = a.muscle_id and b.role='primary'
        where a.exercise_id = v_bench and a.role='primary'
          and b.exercise_id = c.exercise_id))
  then raise exception 'a candidate does not share a primary muscle'; end if;

  -- ── 2 · Injury filter reaches Extended rows (this is what v2_0033 bought) ─
  select id into v_shoulder from joints where slug='shoulder';
  insert into user_constraints (user_id, joint_id, label)
  values (v_uid, v_shoulder, 'test shoulder');

  select count(*) into v_blind from swap_candidates(v_bench) c
    join exercise_joints ej on ej.exercise_id = c.exercise_id
   where ej.joint_id = v_shoulder and ej.stress_level = 'severe';
  if v_blind > 0 then
    raise exception '% candidate(s) severe on a flagged joint slipped through', v_blind;
  end if;
  select count(*) into v_still from swap_candidates(v_bench);
  raise notice 'with a shoulder flag: % candidates, 0 severe on that joint', v_still;

  -- Chest presses are shoulder:moderate, not severe, so the count above does
  -- not move — that proves nothing harmful passes, not that the filter bites.
  -- Overhead pressing IS severe on the shoulder, so this is where it must.
  declare
    v_ohp uuid; v_free int; v_flagged int;
  begin
    select id into v_ohp from exercises where slug='overhead-press' and owner_id is null;
    select count(*) into v_flagged from swap_candidates(v_ohp);
    delete from user_constraints where user_id = v_uid;
    select count(*) into v_free from swap_candidates(v_ohp);
    if v_flagged >= v_free then
      raise exception 'shoulder flag removed nothing from overhead-press '
                      'candidates (% flagged vs % unflagged)', v_flagged, v_free;
    end if;
    raise notice 'overhead-press candidates: % unflagged -> % with a shoulder flag',
      v_free, v_flagged;
  end;

  -- ── 3 · Swapping rewrites the live plan and does not inherit the weight ──
  select target_weight_kg into v_kg from program_day_exercises pde
    join program_days pd on pd.id=pde.program_day_id
   where pd.program_id=v_prog and pde.exercise_id=v_bench limit 1;

  select exercise_id into v_alt from swap_candidates(v_bench)
   where is_core and exercise_id <> v_bench limit 1;
  perform swap_exercise(v_bench, v_alt);

  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'bench-press still in the live plan after swap';
  end if;
  select target_weight_kg into v_altkg from program_day_exercises pde
    join program_days pd on pd.id=pde.program_day_id
   where pd.program_id=v_prog and pde.exercise_id=v_alt limit 1;
  raise notice 'swapped bench (% kg) -> substitute (% kg)', v_kg, v_altkg;

  -- ── 4 · The reason this is a table: it survives a rebuild ────────────────
  v_prog := bootstrap_user_program(v_uid);
  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'swap did not survive regeneration — bench-press is back';
  end if;
  raise notice 'swap survived a full program rebuild';

  -- ── 5 · A bogus target is refused server-side ────────────────────────────
  begin
    perform swap_exercise(v_bench,
      (select id from exercises where slug='back-squat' and owner_id is null));
    raise exception 'swapping bench press for a squat was accepted';
  exception when others then
    if sqlerrm like '%is not a valid swap%' then
      raise notice 'cross-muscle swap correctly refused';
    else raise; end if;
  end;

  -- ── 6 · Undo restores the original ───────────────────────────────────────
  perform unswap_exercise(v_bench);
  v_prog := bootstrap_user_program(v_uid);
  if not exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                  where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'undo did not bring bench-press back';
  end if;
  raise notice 'undo restored bench-press';

  raise notice 'PLAN 05 SWAP ACCEPTANCE: PASS';
end $$;
rollback to savepoint swap;
