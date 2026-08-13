-- =============================================================================
-- LOAD v2 — plan generation rewrite
--
-- One function serves both callers: onboarding's "build my week" and Profile's
-- "Rewrite my week". Changes from the v1 generator:
--
--   * Schedules onto training_weekdays (the actual days), not every-2-days.
--   * has_benched = false → bench prescribed as bar-only 5x5 technique work.
--   * Accepts the onboarding bench calibration (F1) as a PARAMETER — it is an
--     input to generation, not a durable profile fact.
--   * Splits derive from weekday count when no explicit preference.
--   * Barbell loads snap to what the user's plates can build (F3).
--   * experience/environment became nullable (v2_0003) — defaulted here.
--   * SECURITY (audit finding F1/ticket F1): the definer function now verifies
--     p_user_id = auth.uid(). Previously any authenticated user could rewrite
--     any other user's program by calling the RPC directly.
--
-- "Loads stay where they are" (Profile's promise): start loads prefer the
-- user's own logged top sets over catalog defaults — carried over from v1
-- (migration 0009) unchanged.
-- =============================================================================

-- Signature changes (new parameter), so drop the old ones first.
drop function if exists bootstrap_user_program(uuid);
drop function if exists bootstrap_my_program();

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
             coalesce(
               (select max(db.top_weight_kg)
                  from v_exercise_daily_bests db
                 where db.user_id = p_user_id and db.exercise_id = b.id),
               b.default_start_kg
             ) as start_kg
        from best_per_muscle b
       order by b.default_rep_low nulls last, b.slug
       limit 4
    loop
      v_ordinal   := v_ordinal + 1;
      v_is_bench  := v_ex.slug = 'bench-press';
      v_is_barbell := v_ex.uses_barbell;
      v_kg        := v_ex.start_kg;

      -- The onboarding calibration wins over history/defaults for bench.
      if v_is_bench and p_bench_start_kg is not null then
        v_kg := p_bench_start_kg;
      end if;
      -- Never benched: the empty bar, week one, whatever else says.
      if v_is_bench and v_tp.has_benched is false then
        v_kg := coalesce(v_tp.bar_weight_kg, 20);
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

-- Self-only wrapper, same as before. Zero-arg calls still work via the default.
create or replace function bootstrap_my_program(p_bench_start_kg numeric default null)
returns uuid
language plpgsql security invoker as $$
begin
  return bootstrap_user_program(auth.uid(), p_bench_start_kg);
end $$;

grant execute on function bootstrap_my_program(numeric) to authenticated;
