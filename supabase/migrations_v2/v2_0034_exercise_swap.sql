-- =============================================================================
-- v2_0034 — exercise swap (Plan 05, spec §9)
--
-- "Sure could swap the exercise if they want to do a different one for the
-- same muscle."
--
-- WHY A TABLE AND NOT A COLUMN
-- Spec §9 says the swap "survives regeneration". An override written onto
-- program_day_exercises cannot: bootstrap_user_program archives the program
-- and rebuilds program_days from scratch, so the row carrying the override is
-- deleted. A standing substitution keyed on the *replaced exercise* survives
-- by construction, and is simpler — "whenever you would give me X, give me Y".
--
-- Swaps are per exercise, not per slot, so a lift appearing on two days swaps
-- on both. Anything else would be incoherent with the standing preference,
-- which necessarily applies everywhere at the next regeneration.
-- =============================================================================

create table if not exists exercise_swaps (
  user_id          uuid not null references profiles(id) on delete cascade,
  from_exercise_id uuid not null references exercises(id) on delete cascade,
  to_exercise_id   uuid not null references exercises(id) on delete cascade,
  created_at       timestamptz not null default now(),
  primary key (user_id, from_exercise_id),
  constraint exercise_swaps_not_self check (from_exercise_id <> to_exercise_id)
);

alter table exercise_swaps enable row level security;
drop policy if exists exercise_swaps_own on exercise_swaps;
create policy exercise_swaps_own on exercise_swaps
  for all using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

comment on table exercise_swaps is
  'Standing substitutions: whenever the generator would prescribe '
  'from_exercise_id for this user, give them to_exercise_id instead. Survives '
  'program regeneration, which is the whole point (spec §9).';


-- ── Candidates ──────────────────────────────────────────────────────────────
-- Everything sharing a primary muscle with the lift being replaced, passing
-- the same hard filters the generator uses. Since v2_0033 gave the whole
-- catalog joint data, the injury filter genuinely sees Extended rows — before
-- that it waved all 484 of them through.
create or replace function swap_candidates(p_exercise_id uuid)
returns table (
  exercise_id uuid, slug text, name text, is_core boolean,
  mechanic text, equipment text, muscle text,
  min_experience experience_level, demo_path text
)
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  with me as (
    select (select auth.uid()) as uid
  ),
  tp as (
    select coalesce(t.environment, 'commercial_gym') as env,
           coalesce(t.experience, 'intermediate')    as exp
      from training_profiles t, me
     where t.user_id = me.uid and t.valid_to is null
  ),
  target_muscles as (
    select em.muscle_id from exercise_muscles em
     where em.exercise_id = p_exercise_id and em.role = 'primary'
  )
  select distinct on (e.id)
         e.id, e.slug, e.name, e.is_core, e.mechanic,
         (select q.name from exercise_equipment ee join equipment q on q.id = ee.equipment_id
           where ee.exercise_id = e.id order by ee.is_required desc, q.name limit 1),
         m.name, e.min_experience, e.demo_path
    from exercises e
    join exercise_muscles em on em.exercise_id = e.id and em.role = 'primary'
    join muscles m on m.id = em.muscle_id
    cross join tp, me
   where e.owner_id is null
     and e.id <> p_exercise_id
     and em.muscle_id in (select muscle_id from target_muscles)
     and e.load_type in ('weight_reps', 'bodyweight_reps')
     and e.min_experience <= tp.exp
     and not exists (
           select 1 from exercise_equipment ee
            where ee.exercise_id = e.id and ee.is_required
              and not exists (
                    select 1 from environment_equipment env
                     where env.equipment_id = ee.equipment_id
                       and env.environment = tp.env))
     and not exists (
           select 1 from exercise_joints ej
             join user_constraints uc
               on uc.joint_id = ej.joint_id and uc.user_id = me.uid
              and uc.active_to is null
            where ej.exercise_id = e.id and ej.stress_level = 'severe')
   order by e.id;
$$;

revoke all on function swap_candidates(uuid) from public;
grant execute on function swap_candidates(uuid) to authenticated;


-- ── Apply ───────────────────────────────────────────────────────────────────
create or replace function swap_exercise(p_from_exercise_id uuid, p_to_exercise_id uuid)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_tp  training_profiles%rowtype;
  v_kg  numeric;
  v_ok  boolean;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  -- The target must be something we would have offered. Re-checking here
  -- rather than trusting the client keeps equipment, training age and injury
  -- filtering authoritative on the server.
  select exists (select 1 from swap_candidates(p_from_exercise_id) c
                  where c.exercise_id = p_to_exercise_id) into v_ok;
  if not v_ok then
    raise exception 'exercise % is not a valid swap for %',
      p_to_exercise_id, p_from_exercise_id;
  end if;

  insert into exercise_swaps (user_id, from_exercise_id, to_exercise_id)
  values (v_uid, p_from_exercise_id, p_to_exercise_id)
  on conflict (user_id, from_exercise_id)
    do update set to_exercise_id = excluded.to_exercise_id, created_at = now();

  select * into v_tp from training_profiles
   where user_id = v_uid and valid_to is null;

  -- Spec §9: the new lift starts from its OWN history, else its catalog
  -- default. It never inherits the replaced lift's weight — 60kg of dumbbell
  -- row is not 60kg of barbell row.
  select max(db.top_weight_kg) into v_kg
    from v_exercise_daily_bests db
   where db.user_id = v_uid and db.exercise_id = p_to_exercise_id;

  if v_kg is null then
    select e.default_start_kg into v_kg from exercises e where e.id = p_to_exercise_id;
    if v_tp.has_benched is false and v_kg is not null and v_kg > 0 then
      v_kg := round(v_kg * 0.4, 1);
    end if;
  end if;
  if v_kg is not null then
    v_kg := snap_to_loadable(v_uid, v_kg);
  end if;

  -- Apply to the live program straight away, so the change is visible now
  -- rather than only after the next rebuild.
  update program_day_exercises pde
     set exercise_id = p_to_exercise_id,
         target_weight_kg = v_kg
    from program_days pd
    join programs p on p.id = pd.program_id
   where pde.program_day_id = pd.id
     and p.user_id = v_uid and p.status = 'active'
     and pde.exercise_id = p_from_exercise_id
     -- Never create a duplicate lift within one day.
     and not exists (select 1 from program_day_exercises x
                      where x.program_day_id = pde.program_day_id
                        and x.exercise_id = p_to_exercise_id);
end $$;

revoke all on function swap_exercise(uuid, uuid) from public;
grant execute on function swap_exercise(uuid, uuid) to authenticated;


-- ── Undo ────────────────────────────────────────────────────────────────────
-- Dropping the preference alone would leave the current program still showing
-- the substitute, so this reverses the live rows too.
create or replace function unswap_exercise(p_from_exercise_id uuid)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_to  uuid;
  v_kg  numeric;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  delete from exercise_swaps
   where user_id = v_uid and from_exercise_id = p_from_exercise_id
  returning to_exercise_id into v_to;
  if v_to is null then return; end if;

  select coalesce(
           (select max(db.top_weight_kg) from v_exercise_daily_bests db
             where db.user_id = v_uid and db.exercise_id = p_from_exercise_id),
           (select e.default_start_kg from exercises e where e.id = p_from_exercise_id))
    into v_kg;
  if v_kg is not null then v_kg := snap_to_loadable(v_uid, v_kg); end if;

  update program_day_exercises pde
     set exercise_id = p_from_exercise_id, target_weight_kg = v_kg
    from program_days pd
    join programs p on p.id = pd.program_id
   where pde.program_day_id = pd.id
     and p.user_id = v_uid and p.status = 'active'
     and pde.exercise_id = v_to
     and not exists (select 1 from program_day_exercises x
                      where x.program_day_id = pde.program_day_id
                        and x.exercise_id = p_from_exercise_id);
end $$;

revoke all on function unswap_exercise(uuid) from public;
grant execute on function unswap_exercise(uuid) to authenticated;
