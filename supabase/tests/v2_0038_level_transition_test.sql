-- Plan 06 acceptance (spec §8.1, §8.2, §13.6, §13.7).
--
-- Promotion must be earned on all three counts, arrive as a proposal, never
-- name the tier, version the profile on accept, and stop nagging on decline.

savepoint lvl;

create or replace function _seed(
  p_uid uuid, p_ex uuid, p_days int[], p_kg numeric, p_reps int, p_rir int
) returns void language plpgsql as $$
declare v_ws uuid; v_se uuid; d int;
begin
  foreach d in array p_days loop
    insert into workout_sessions (user_id, title, performed_on, status, started_at, completed_at)
    values (p_uid, 'seed', user_today(p_uid) - d, 'completed',
            now() - (d||' days')::interval, now() - (d||' days')::interval + interval '1 hour')
    returning id into v_ws;
    insert into session_exercises (user_id, session_id, exercise_id, ordinal)
    values (p_uid, v_ws, p_ex, 1) returning id into v_se;
    insert into session_sets (user_id, session_exercise_id, set_number,
                              weight_kg, reps, rir, is_completed, kind)
    values (p_uid, v_se, 1, p_kg, p_reps, p_rir, true, 'working');
  end loop;
end $$;

DO $$
declare
  v_uid uuid; v_prog uuid; v_bench uuid; v_squat uuid;
  v_sig record; v_pid uuid; v_pid2 uuid; v_body text; v_exp text; v_vers int;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

  delete from coach_proposals where user_id = v_uid;
  delete from workout_sessions where user_id = v_uid;
  update training_profiles set experience='beginner', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;

  select id into v_bench from exercises where slug='bench-press' and owner_id is null;
  select id into v_squat from exercises where slug='back-squat'  and owner_id is null;

  -- ── 1 · A fresh beginner is not eligible ────────────────────────────────
  select * into v_sig from level_promotion_signal(v_uid);
  if v_sig.eligible then raise exception 'promoted a lifter with no history'; end if;
  raise notice 'no history            -> not eligible (evidence=%, weeks=%)',
    v_sig.evidence, v_sig.weeks;

  -- ── 2 · Stalled lifts but too little history: still not eligible ────────
  -- A stall in lift_status() is the same top weight for three sessions AND
  -- hitting the top of the rep range at least twice — maxing the reps out and
  -- still unable to add weight. rep_high is 12 for build_muscle, so the seeds
  -- below use 12; five reps would not be a stall, just a light day.
  perform _seed(v_uid, v_bench, array[2,4,6],  60, 12, 0);
  perform _seed(v_uid, v_squat, array[3,5,7], 100, 12, 0);
  select * into v_sig from level_promotion_signal(v_uid);
  if v_sig.eligible then
    raise exception 'promoted on % weeks of history', v_sig.weeks;
  end if;
  raise notice 'stalled, %% weeks only -> not eligible (evidence=%)', v_sig.evidence;

  -- ── 3 · Add 8+ weeks AND a survived deload: now eligible ────────────────
  -- The dip to 54kg and the climb back to 60 is the deload §8.1 requires.
  perform _seed(v_uid, v_bench, array[70,63,56,49], 60, 12, 1);
  perform _seed(v_uid, v_bench, array[42],          54,  8, 1);  -- the reset
  perform _seed(v_uid, v_bench, array[35,28,21],    60, 12, 0);  -- back, stuck
  perform _seed(v_uid, v_squat, array[70,63,56,49,42,35], 100, 12, 1);

  if not deload_survived(v_uid, v_bench) then
    raise exception 'deload_survived did not see the 60 -> 54 -> 60 pattern';
  end if;
  select * into v_sig from level_promotion_signal(v_uid);
  if not v_sig.eligible then
    raise exception 'still not eligible: evidence=% weeks=% deload=%',
      v_sig.evidence, v_sig.weeks, v_sig.deload_ok;
  end if;
  raise notice 'full evidence         -> ELIGIBLE (% lifts, % weeks, deload=%)',
    v_sig.evidence, v_sig.weeks, v_sig.deload_ok;

  -- ── 4 · It arrives as a proposal, and never names the tier (§13.7) ──────
  v_pid := propose_level_change(v_uid);
  if v_pid is null then raise exception 'eligible but no proposal created'; end if;
  select cm.content into v_body from coach_proposals cp
    join coach_messages cm on cm.id = cp.message_id where cp.id = v_pid;
  raise notice 'proposal: "%"', v_body;
  if v_body ~* '\m(beginner|intermediate|advanced|level|tier)\M' then
    raise exception 'the tier label leaked into user-facing copy: %', v_body;
  end if;

  -- Asking twice must not stack proposals.
  if propose_level_change(v_uid) is not null then
    raise exception 'created a second proposal while one was pending';
  end if;
  raise notice 'second call           -> no duplicate proposal';

  -- ── 5 · Decline: no plan change, and no re-ask on a timer (§13.6) ───────
  perform resolve_level_change(v_pid, false);
  select experience::text into v_exp from training_profiles
   where user_id=v_uid and valid_to is null;
  if v_exp <> 'beginner' then raise exception 'decline changed the level to %', v_exp; end if;
  if propose_level_change(v_uid) is not null then
    raise exception 're-asked immediately after a decline';
  end if;
  raise notice 'declined              -> level unchanged, not re-asked';

  -- ── 6 · Accept versions the profile rather than overwriting it (§8.2) ───
  update coach_proposals set status='pending', resolved_at=null where id=v_pid;
  select count(*) into v_vers from training_profiles where user_id=v_uid;
  perform resolve_level_change(v_pid, true);

  select experience::text into v_exp from training_profiles
   where user_id=v_uid and valid_to is null;
  if v_exp <> 'intermediate' then
    raise exception 'accept did not move the level (got %)', v_exp;
  end if;
  if (select count(*) from training_profiles where user_id=v_uid) <= v_vers then
    raise exception 'accept overwrote the profile instead of versioning it';
  end if;
  if not exists (select 1 from training_profiles
                  where user_id=v_uid and valid_to is not null and experience='beginner') then
    raise exception 'the superseded row did not keep its old level';
  end if;
  raise notice 'accepted              -> now %, prior row preserved for the audit trail', v_exp;

  -- The plan must actually be rebuilt, or the level change means nothing.
  if not exists (select 1 from programs where user_id=v_uid and status='active'
                   and starts_on = current_date) then
    raise exception 'accept did not rebuild the program';
  end if;
  raise notice 'accepted              -> program rebuilt';

  -- ── 7 · Already promoted: no further proposal ──────────────────────────
  if propose_level_change(v_uid) is not null then
    raise exception 'proposed a level change straight after promoting';
  end if;
  raise notice 'after promotion       -> nothing further proposed';

  raise notice 'PLAN 06 LEVEL TRANSITION ACCEPTANCE: PASS';
end $$;
rollback to savepoint lvl;
