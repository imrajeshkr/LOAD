-- =============================================================================
-- v2_0014 — a rewrite clears the old forward schedule first
--
-- bootstrap_user_program archives the old program and inserts a fresh set of
-- scheduled_workouts, but never deleted the old ones. They point at the
-- archived program's days (a different program_day_id), so `on conflict do
-- nothing` never deduped them — both rotations then rendered on the calendar
-- at once (e.g. change M/W/F → M–S and every day shows two labels).
--
-- Fix: before scheduling, delete this user's FUTURE scheduled_workouts
-- (scheduled_for >= today). Forward-only by design — past days keep the labels
-- they were planned under, so a change never rewrites history or retroactively
-- flags a day that is now off as "missed".
--
-- Only the delete is new; the rest of the function is verbatim from v2_0011.
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
  v_split     split_type;
  v_program   uuid;
  v_day       uuid;
  v_patterns  text[];
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
  v_d         date;
  v_day_ids   uuid[];
begin
  -- Security: definer runs above RLS, so this check is the only guard.
  if p_user_id is distinct from auth.uid() then
    raise exception 'not authorized';
  end if;

  select * into v_tp from training_profiles
   where user_id = p_user_id and valid_to is null;
  if not found then
    raise exception 'no current training profile for user %', p_user_id;
  end if;

  -- v2 onboarding no longer asks these; default them.
  v_env      := coalesce(v_tp.environment, 'commercial_gym');
  v_weekdays := coalesce(v_tp.training_weekdays, '{}');
  v_daycount := coalesce(nullif(cardinality(v_weekdays), 0), v_tp.days_per_week, 3);

  -- Split: explicit preference wins; otherwise derived from day count
  -- (mirrors the client's daysVerdict copy).
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
      v_patterns := array['push','pull','legs'];
      v_labels   := array['Push day','Pull day','Leg day'];
    when 'upper_lower' then
      v_patterns := array['push','legs'];
      v_labels   := array['Upper body','Lower body'];
    else
      v_patterns := array['push','pull'];
      v_labels   := array['Full body A','Full body B'];
  end case;

  insert into programs (user_id, name, goal, split, days_per_week, status,
                        authored_by, starts_on)
  values (p_user_id, initcap(replace(v_split::text, '_', ' ')),
          v_tp.goal, v_split, v_daycount, 'active', 'coach_ai', v_start)
  returning id into v_program;

  for v_i in 1 .. array_length(v_patterns, 1) loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i]) returning id into v_day;
    v_day_ids := array_append(v_day_ids, v_day);

    v_ordinal := 0;
    for v_ex in
      with candidates as (
        select e.id, e.slug, e.name, e.default_rep_low, e.default_rep_high,
               e.default_start_kg, em.muscle_id,
               exists (select 1 from exercise_equipment ee
                         join equipment q on q.id = ee.equipment_id
                        where ee.exercise_id = e.id and q.slug = 'barbell')
                 as uses_barbell
          from exercises e
          join exercise_muscles em on em.exercise_id = e.id and em.role = 'primary'
         where e.owner_id is null
           and e.pattern = v_patterns[v_i]
           and e.load_type in ('weight_reps','bodyweight_reps')
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
               default_start_kg, uses_barbell
          from candidates
         order by muscle_id, default_rep_low nulls last, slug
      )
      select b.id, b.slug, b.default_rep_low, b.default_rep_high, b.uses_barbell,
             (select max(db.top_weight_kg)
                from v_exercise_daily_bests db
               where db.user_id = p_user_id and db.exercise_id = b.id) as history_kg,
             b.default_start_kg
        from best_per_muscle b
       order by b.default_rep_low nulls last, b.slug
       limit 4
    loop
      v_ordinal    := v_ordinal + 1;
      v_is_bench   := v_ex.slug = 'bench-press';
      v_is_barbell := v_ex.uses_barbell;
      v_has_history := v_ex.history_kg is not null;
      v_kg         := coalesce(v_ex.history_kg, v_ex.default_start_kg);

      -- The onboarding calibration wins over history/defaults for bench.
      if v_is_bench and p_bench_start_kg is not null then
        v_kg := p_bench_start_kg;
        v_has_history := true; -- a fresh calibration is not a beginner guess
      end if;
      -- Never benched is our only "brand new lifter" signal (v2 never asks
      -- experience directly). Applies to every compound, not just bench, but
      -- only when there is no real logged history to override — a lifter who
      -- has actually done the movement keeps "loads stay where they are".
      if v_tp.has_benched is false and not v_has_history then
        if v_is_barbell then
          v_kg := coalesce(v_tp.bar_weight_kg, 20);
        elsif v_kg is not null and v_kg > 0 then
          v_kg := round(v_kg * 0.4, 1);
        end if;
      end if;
      -- A barbell load must be buildable from the user's plates.
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

  -- NEW (v2_0014): forward-only clear. Drop this user's future schedule (the
  -- archived program's rows, and any partial new ones) before laying down the
  -- new rotation, so a "Rewrite my week" replaces the calendar going forward
  -- instead of stacking a second rotation on top of it. Past days are left
  -- untouched — history keeps its original labels and nothing is re-flagged.
  delete from scheduled_workouts
   where user_id = p_user_id and scheduled_for >= v_start;

  -- Scheduling: the next 14 days, on the user's actual weekdays, cycling
  -- through the rotation. Falls back to every-other-day if no weekdays set.
  if cardinality(v_weekdays) > 0 then
    for v_i in 0 .. 13 loop
      v_d := v_start + v_i;
      if extract(isodow from v_d)::smallint = any (v_weekdays) then
        insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
        values (p_user_id, v_program,
                v_day_ids[(v_slot % array_length(v_day_ids, 1)) + 1], v_d)
        on conflict do nothing;
        v_slot := v_slot + 1;
      end if;
    end loop;
  else
    insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
    select p_user_id, v_program, d.id,
           v_start + ((d.ordinal - 1) + (w * array_length(v_patterns, 1))) * 2
      from program_days d cross join generate_series(0, 1) as w
     where d.program_id = v_program
    on conflict do nothing;
  end if;

  return v_program;
end $$;

revoke all on function bootstrap_user_program(uuid, numeric) from public;
grant execute on function bootstrap_user_program(uuid, numeric) to authenticated;
