-- =============================================================================
-- v2_0026 — the generator may only prescribe enriched, level-appropriate lifts
--
-- Two hard filters the selection was missing, both from spec §6 Stage 3.
--
-- 1. is_core. The catalog import (v2_0024) added 494 Extended exercises that
--    carry NO joint-stress rows. The injury filter excludes lifts with 'severe'
--    stress on a flagged joint — but an exercise with no joint data at all
--    passes that test trivially. So without this filter, a lifter who flagged a
--    shoulder could be prescribed any of 494 movements with the injury routing
--    silently blind. Only Core rows (authored joint stress + contributions) may
--    be auto-selected; Extended stays browse/swap only, as designed.
--
-- 2. min_experience. A beginner should never be auto-given an advanced lift.
--    Also used as the FIRST tie-break, so when two exercises for a muscle have
--    the same rep range the beginner-appropriate one wins instead of whichever
--    slug happens to sort earlier alphabetically. (Real case: a novice was
--    prescribed overhead-tricep-ext — intermediate, severe elbow stress — over
--    tricep-pushdown purely because 'o' < 't'.)
--
-- Existing behaviour is preserved for anyone whose experience is NULL: it
-- coalesces to 'intermediate', which is what the backfill assigned.
-- =============================================================================

create or replace function bootstrap_user_program(
  p_user_id        uuid,
  p_bench_start_kg numeric default null
)
returns uuid
language plpgsql
security definer set search_path = public as $$
declare
  v_tp        training_profiles%rowtype;
  v_env       train_environment;
  v_exp       experience_level;
  v_split     split_type;
  v_program   uuid;
  v_day       uuid;
  v_daysets  text[];   -- comma-separated pattern set, one entry per program_day
  v_slots    int;      -- exercises for the current day
  v_labels    text[];
  v_i         int;
  v_ex        record;
  v_ordinal   int;
  v_start     date := current_date;
  v_daycount  int;
  v_weekdays  smallint[];
  v_is_bench  boolean;
  v_kg        numeric;
  v_is_barbell boolean;
  v_has_history boolean;
  v_slot      int := 0;
  v_wd        smallint;
  v_day_ids   uuid[];
begin
  if p_user_id is distinct from auth.uid() then
    raise exception 'not authorized';
  end if;

  select * into v_tp from training_profiles
   where user_id = p_user_id and valid_to is null;
  if not found then
    raise exception 'no current training profile for user %', p_user_id;
  end if;

  v_env      := coalesce(v_tp.environment, 'commercial_gym');
  v_exp      := coalesce(v_tp.experience, 'intermediate');
  v_weekdays := coalesce(v_tp.training_weekdays, '{}');
  v_daycount := coalesce(nullif(cardinality(v_weekdays), 0), v_tp.days_per_week, 3);

  if v_tp.split_preference is not null and v_tp.split_preference <> 'no_preference' then
    v_split := v_tp.split_preference;
  elsif v_daycount <= 3 then v_split := 'full_body';
  elsif v_daycount <= 5 then v_split := 'upper_lower';
  else                       v_split := 'push_pull_legs';
  end if;

  update programs set status = 'archived'
   where user_id = p_user_id and status = 'active';

  case v_split
    when 'push_pull_legs' then
      v_daysets := array['push', 'pull', 'legs'];
      v_labels  := array['Push day','Pull day','Leg day'];
    when 'upper_lower' then
      -- Upper is push AND pull; lower is legs.
      v_daysets := array['push,pull', 'legs'];
      v_labels  := array['Upper body','Lower body'];
    else
      -- Full body trains legs on BOTH days; upper alternates push / pull so the
      -- week still covers every muscle group.
      v_daysets := array['push,legs', 'pull,legs'];
      v_labels  := array['Full body A','Full body B'];
  end case;

  insert into programs (user_id, name, goal, split, days_per_week, status,
                        authored_by, starts_on)
  values (p_user_id, initcap(replace(v_split::text, '_', ' ')),
          v_tp.goal, v_split, v_daycount, 'active', 'coach_ai', v_start)
  returning id into v_program;

  for v_i in 1 .. array_length(v_daysets, 1) loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i]) returning id into v_day;
    v_day_ids := array_append(v_day_ids, v_day);

    v_ordinal := 0;

    -- One slot per primary muscle this day covers, kept to a sane session
    -- length. Upper (8 muscles) gets 6; Legs (4) gets 4.
    select least(greatest(count(distinct em.muscle_id), 3), 6)
      into v_slots
      from exercises e
      join exercise_muscles em on em.exercise_id = e.id and em.role = 'primary'
     where e.owner_id is null
       and e.pattern = any(string_to_array(v_daysets[v_i], ','));

    for v_ex in
      with candidates as (
        select e.id, e.slug, e.name, e.default_rep_low, e.default_rep_high,
               e.default_start_kg, e.min_experience, em.muscle_id,
               exists (select 1 from exercise_equipment ee
                         join equipment q on q.id = ee.equipment_id
                        where ee.exercise_id = e.id and q.slug = 'barbell')
                 as uses_barbell
          from exercises e
          join exercise_muscles em on em.exercise_id = e.id and em.role = 'primary'
         where e.owner_id is null
           and e.pattern = any(string_to_array(v_daysets[v_i], ','))
           and e.load_type in ('weight_reps','bodyweight_reps')
           -- Only Core may be auto-prescribed: Extended rows carry no
           -- joint-stress data, so the injury filter below cannot see them
           -- and would wave every one of them through.
           and e.is_core
           -- Never hand a lifter something above their training age.
           and e.min_experience <= v_exp
           and not exists (
                 select 1 from exercise_equipment ee
                  where ee.exercise_id = e.id and ee.is_required
                    and not exists (
                          select 1 from environment_equipment env
                           where env.equipment_id = ee.equipment_id
                             and env.environment = v_env))
           and not exists (
                 select 1 from exercise_joints ej
                   join user_constraints uc
                     on uc.joint_id = ej.joint_id and uc.user_id = p_user_id
                    and uc.active_to is null
                  where ej.exercise_id = e.id and ej.stress_level = 'severe')
      ),
      best_per_muscle as (
        select distinct on (muscle_id)
               id, slug, default_rep_low, default_rep_high,
               default_start_kg, uses_barbell, min_experience
          from candidates
         order by muscle_id, min_experience, default_rep_low nulls last, slug
      )
      select b.id, b.slug, b.default_rep_low, b.default_rep_high, b.uses_barbell,
             (select max(db.top_weight_kg)
                from v_exercise_daily_bests db
               where db.user_id = p_user_id and db.exercise_id = b.id) as history_kg,
             b.default_start_kg
        from best_per_muscle b
       order by b.default_rep_low nulls last, b.slug
       limit v_slots
    loop
      v_ordinal    := v_ordinal + 1;
      v_is_bench   := v_ex.slug = 'bench-press';
      v_is_barbell := v_ex.uses_barbell;
      v_has_history := v_ex.history_kg is not null;
      v_kg         := coalesce(v_ex.history_kg, v_ex.default_start_kg);

      if v_is_bench and p_bench_start_kg is not null then
        v_kg := p_bench_start_kg;
        v_has_history := true;
      end if;
      if v_tp.has_benched is false and not v_has_history then
        if v_is_barbell then
          v_kg := coalesce(v_tp.bar_weight_kg, 20);
        elsif v_kg is not null and v_kg > 0 then
          v_kg := round(v_kg * 0.4, 1);
        end if;
      end if;
      if v_is_barbell and v_kg is not null then
        v_kg := snap_to_loadable(p_user_id, v_kg);
      end if;

      insert into program_day_exercises
        (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high,
         target_weight_kg, rest_seconds)
      values
        (v_day, v_ex.id, v_ordinal,
         case when v_is_bench and v_tp.has_benched is false then 5
              when v_ordinal = 1 then 4 else 3 end,
         case when v_is_bench and v_tp.has_benched is false then 5
              else coalesce(v_ex.default_rep_low, 8) end,
         case when v_is_bench and v_tp.has_benched is false then 5
              else coalesce(v_ex.default_rep_high, 12) end,
         v_kg,
         case when v_ordinal = 1 then 180 else 120 end);
    end loop;
  end loop;

  -- Forward-only reset: drop this user's slots (old programs') and future
  -- schedule before laying down the new pattern. Past days keep their labels.
  delete from program_weekday_slots where user_id = p_user_id;
  delete from scheduled_workouts
   where user_id = p_user_id and scheduled_for >= v_start;

  if cardinality(v_weekdays) > 0 then
    -- Default pattern: training weekdays ascending, cycling the rotation.
    v_slot := 0;
    for v_wd in select w from unnest(v_weekdays) w order by w loop
      insert into program_weekday_slots (program_id, user_id, weekday, program_day_id)
      values (v_program, p_user_id, v_wd,
              v_day_ids[(v_slot % array_length(v_day_ids, 1)) + 1]);
      v_slot := v_slot + 1;
    end loop;

    -- Materialise the rolling 35-day window from the pattern.
    insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
    select p_user_id, v_program, s.program_day_id, d::date
      from generate_series(v_start, v_start + 34, interval '1 day') d
      join program_weekday_slots s
        on s.program_id = v_program
       and s.weekday = extract(isodow from d)::smallint
    on conflict do nothing;
  else
    -- No weekdays set: keep the old every-other-day fallback (no pattern).
    insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
    select p_user_id, v_program, d.id,
           v_start + ((d.ordinal - 1) + (w * array_length(v_daysets, 1))) * 2
      from program_days d cross join generate_series(0, 1) as w
     where d.program_id = v_program
    on conflict do nothing;
  end if;

  return v_program;
end $$;

revoke all on function bootstrap_user_program(uuid, numeric) from public;
grant execute on function bootstrap_user_program(uuid, numeric) to authenticated;
