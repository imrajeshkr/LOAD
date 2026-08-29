-- =============================================================================
-- v2_0052 — a swap can be for today only
--
-- Replacing an exercise had exactly one meaning: forever. But "the squat rack
-- was busy so I did leg press once" is not a programme change, and forcing it
-- to be one is how a plan drifts away from what the lifter actually chose.
--
-- Rather than a second mechanism, the existing standing swap gains an end
-- date. Null still means standing, so every existing row keeps its meaning.
-- =============================================================================

alter table exercise_swaps
  add column if not exists expires_on date;

comment on column exercise_swaps.expires_on is
  'Last day this substitution applies. Null = standing, which is what every '
  'row created before v2_0052 means.';

-- p_until null keeps the old behaviour, so existing callers are unaffected.
create or replace function swap_exercise(
  p_from_exercise_id uuid,
  p_to_exercise_id uuid,
  p_until date default null
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_tp  training_profiles%rowtype;
  v_kg  numeric;
  v_ok  boolean;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  select exists (select 1 from swap_candidates(p_from_exercise_id) c
                  where c.exercise_id = p_to_exercise_id) into v_ok;
  if not v_ok then
    raise exception 'exercise % is not a valid swap for %',
      p_to_exercise_id, p_from_exercise_id;
  end if;

  insert into exercise_swaps (user_id, from_exercise_id, to_exercise_id, expires_on)
  values (v_uid, p_from_exercise_id, p_to_exercise_id, p_until)
  on conflict (user_id, from_exercise_id)
    do update set to_exercise_id = excluded.to_exercise_id,
                  expires_on     = excluded.expires_on,
                  created_at     = now();

  select * into v_tp from training_profiles
   where user_id = v_uid and valid_to is null;

  select max(db.top_weight_kg) into v_kg
    from v_exercise_daily_bests db
   where db.user_id = v_uid and db.exercise_id = p_to_exercise_id;

  if v_kg is null then
    select e.default_start_kg into v_kg from exercises e where e.id = p_to_exercise_id;
    if v_tp.has_benched is false and v_kg is not null and v_kg > 0 then
      v_kg := round(v_kg * 0.4, 1);
    end if;
  end if;
  if v_kg is not null then v_kg := snap_to_loadable(v_uid, v_kg); end if;

  update program_day_exercises pde
     set exercise_id = p_to_exercise_id,
         target_weight_kg = v_kg
    from program_days pd
    join programs p on p.id = pd.program_id
   where pde.program_day_id = pd.id
     and p.user_id = v_uid and p.status = 'active'
     and pde.exercise_id = p_from_exercise_id
     and not exists (select 1 from program_day_exercises x
                      where x.program_day_id = pde.program_day_id
                        and x.exercise_id = p_to_exercise_id);
end $$;

revoke all on function swap_exercise(uuid, uuid, date) from public;
grant execute on function swap_exercise(uuid, uuid, date) to authenticated;

-- An expired swap must stop being reapplied when the plan is rebuilt.
create or replace function _v2_0052_patch() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'bootstrap_user_program';
  if position('from exercise_swaps s, program_days pd' in v_src) = 0 then
    raise exception 'v2_0052: bootstrap swap post-pass not found — refusing to patch blind';
  end if;
  execute 'create or replace function public.bootstrap_user_program('
       || 'p_user_id uuid, p_bench_start_kg numeric default null) returns uuid '
       || 'language plpgsql security definer '
       || 'set search_path to ''public'', ''pg_temp'' as $body$'
       || replace(v_src,
            'where s.user_id = p_user_id',
            'where s.user_id = p_user_id'
            || chr(10) || '     and (s.expires_on is null or s.expires_on >= v_start)')
       || '$body$';
end $patch$;
select _v2_0052_patch();
drop function _v2_0052_patch();
