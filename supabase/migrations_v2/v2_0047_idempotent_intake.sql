-- =============================================================================
-- v2_0047 — make finishing onboarding possible more than once
--
-- THE BUG
-- submitOnboarding blindly INSERTs into training_profiles and nutrition_targets.
-- Both are versioned tables carrying a unique index on (user_id) WHERE
-- valid_to IS NULL, so the second attempt fails with 23505 and the app shows
-- "Couldn't build your plan — try again". Trying again fails identically,
-- forever.
--
-- It is a lockout, not an inconvenience, because RootGate routes any signed-in
-- user WITHOUT an active program to onboarding. So the moment a first attempt
-- half-succeeds — profile written, program not — the account can never reach
-- the app again. One live account (rajesh.kumar@kitab.com) is in exactly that
-- state: training profile present, zero programs.
--
-- WHY THIS IS AN RPC AND NOT A CLIENT FIX
-- The obvious client-side repair is "close the old row, then insert the new
-- one". That is two round trips with no transaction around them: if the close
-- lands and the insert fails, the user is left with NO current profile, which
-- is worse than the bug. Superseding and inserting have to be atomic, so they
-- belong in one function.
--
-- Re-running intake also used to stack injury flags, since user_constraints
-- was appended to rather than replaced. Handled here too.
-- =============================================================================

create or replace function submit_intake(p jsonb)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  c     jsonb;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  -- Supersede rather than overwrite: the previous answers stay readable, which
  -- is the same convention v2_0038 uses for a level change.
  -- clock_timestamp(), not now(): now() is the TRANSACTION timestamp and does
  -- not advance, so superseding a row created in the same transaction would
  -- set valid_to = valid_from and trip the valid_to > valid_from check. The
  -- greatest() guards the same collision across a fast double-submit.
  update training_profiles
     set valid_to = greatest(clock_timestamp(), valid_from + interval '1 millisecond')
   where user_id = v_uid and valid_to is null;

  insert into training_profiles (
    user_id, goal, goals, goal_is_coach_choice, target_direction,
    target_weight_kg, training_weekdays, days_per_week, split_preference,
    experience, environment, bar_weight_kg, has_benched, intake_confirmed)
  values (
    v_uid,
    (p->>'goal')::training_goal,
    (select array_agg(x::training_goal)
       from jsonb_array_elements_text(coalesce(p->'goals','[]'::jsonb)) x),
    coalesce((p->>'goal_is_coach_choice')::boolean, false),
    nullif(p->>'target_direction','')::weight_goal_direction,
    (p->>'target_weight_kg')::numeric,
    (select coalesce(array_agg(x::smallint), '{}')
       from jsonb_array_elements_text(coalesce(p->'training_weekdays','[]'::jsonb)) x),
    coalesce((p->>'days_per_week')::int, 3),
    nullif(p->>'split_preference', '')::split_type,
    nullif(p->>'experience', '')::experience_level,
    nullif(p->>'environment', '')::train_environment,
    (p->>'bar_weight_kg')::numeric,
    (p->>'has_benched')::boolean,
    -- The lifter answered the two intake steps themselves, so the Profile
    -- prompt from v2_0032 must not ask again.
    true);

  -- nutrition_targets versions by DATE, not timestamp, and the table checks
  -- valid_to > valid_from. A row opened earlier today therefore cannot be
  -- closed today — so a same-day row is discarded rather than superseded.
  -- There is no history worth keeping in "we guessed your protein twice in one
  -- afternoon".
  delete from nutrition_targets
   where user_id = v_uid and valid_to is null and valid_from >= current_date;
  update nutrition_targets set valid_to = current_date
   where user_id = v_uid and valid_to is null;
  insert into nutrition_targets (user_id, protein_g)
  values (v_uid, coalesce((p->>'protein_g')::int, 120));

  -- Replace, do not append: re-running intake should not leave a lifter with
  -- the same knee flagged three times.
  delete from user_constraints where user_id = v_uid and active_to is null;
  for c in select * from jsonb_array_elements(coalesce(p->'constraints', '[]'::jsonb))
  loop
    insert into user_constraints (user_id, joint_id, label, side, severity, active_from)
    values (v_uid,
            nullif(c->>'joint_id','')::uuid,
            c->>'label',
            nullif(c->>'side',''),
            coalesce(nullif(c->>'severity','')::severity_level, 'mild'),
            current_date);
  end loop;
end $$;

revoke all on function submit_intake(jsonb) from public;
grant execute on function submit_intake(jsonb) to authenticated;
