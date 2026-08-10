-- =============================================================================
-- LOAD — pick a balanced session, not an alphabetical one
--
-- The first cut of bootstrap_user_program selected `order by e.name limit 4`,
-- which produced a Push Day of Bench Press, Cable Fly, DB Bench Press and
-- Floor Press: three chest presses and a fly, with nothing for shoulders or
-- triceps. Alphabetical order is not a training principle.
--
-- This picks one movement per primary muscle, compound-first, so each day
-- covers its pattern properly:
--   push  → chest · front delt · triceps · side delt
--   pull  → lats · rhomboids · biceps · rear delt
--   legs  → quads · hamstrings · glutes · calves
--
-- "Compound-first" is inferred from the default rep range: a movement
-- prescribed at 6 reps is a heavier, more systemic lift than one prescribed
-- at 15, so ordering by rep_low ascending puts the main lift first and the
-- isolation work after it — which is also the order you want to train in.
-- =============================================================================

create or replace function bootstrap_user_program(p_user_id uuid)
returns uuid
language plpgsql
security definer set search_path = public as $$
declare
  v_tp        training_profiles%rowtype;
  v_program   uuid;
  v_day       uuid;
  v_patterns  text[];
  v_labels    text[];
  v_i         int;
  v_ex        record;
  v_ordinal   int;
  v_start     date := current_date;
begin
  select * into v_tp
    from training_profiles
   where user_id = p_user_id and valid_to is null;

  if not found then
    raise exception 'no current training profile for user %', p_user_id;
  end if;

  update programs set status = 'archived'
   where user_id = p_user_id and status = 'active';

  case v_tp.split_preference
    when 'push_pull_legs' then
      v_patterns := array['push', 'pull', 'legs'];
      v_labels   := array['Push Day', 'Pull Day', 'Leg Day'];
    when 'upper_lower' then
      v_patterns := array['push', 'legs'];
      v_labels   := array['Upper Day', 'Lower Day'];
    when 'full_body' then
      v_patterns := array['push'];
      v_labels   := array['Full Body'];
    else
      v_patterns := array['push', 'pull', 'legs'];
      v_labels   := array['Push Day', 'Pull Day', 'Leg Day'];
  end case;

  insert into programs (user_id, name, goal, split, days_per_week, status, authored_by, starts_on)
  values (p_user_id,
          initcap(replace(v_tp.split_preference::text, '_', ' ')),
          v_tp.goal, v_tp.split_preference, v_tp.days_per_week,
          'active', 'template', v_start)
  returning id into v_program;

  for v_i in 1 .. array_length(v_patterns, 1) loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i])
    returning id into v_day;

    v_ordinal := 0;
    for v_ex in
      with candidates as (
        select e.id, e.name, e.default_rep_low, e.default_rep_high, em.muscle_id
          from exercises e
          join exercise_muscles em
            on em.exercise_id = e.id and em.role = 'primary'
         where e.owner_id is null
           and e.pattern = v_patterns[v_i]
           and e.load_type in ('weight_reps', 'bodyweight_reps')
           -- their gym can equip it
           and not exists (
                 select 1 from exercise_equipment ee
                  where ee.exercise_id = e.id and ee.is_required
                    and not exists (
                          select 1 from environment_equipment env
                           where env.equipment_id = ee.equipment_id
                             and env.environment = v_tp.environment))
           -- and it doesn't hammer a joint they've flagged
           and not exists (
                 select 1 from exercise_joints ej
                   join user_constraints uc
                     on uc.joint_id = ej.joint_id
                    and uc.user_id = p_user_id
                    and uc.active_to is null
                  where ej.exercise_id = e.id
                    and ej.stress_level = 'severe')
      ),
      -- one movement per muscle, the most compound available for it
      best_per_muscle as (
        select distinct on (muscle_id) id, name, default_rep_low, default_rep_high
          from candidates
         order by muscle_id, default_rep_low nulls last, name
      )
      select id, default_rep_low, default_rep_high
        from best_per_muscle
       order by default_rep_low nulls last, name
       limit 4
    loop
      v_ordinal := v_ordinal + 1;
      insert into program_day_exercises
        (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high, rest_seconds)
      values
        (v_day, v_ex.id, v_ordinal,
         case when v_ordinal = 1 then 4 else 3 end,
         coalesce(v_ex.default_rep_low, 8),
         coalesce(v_ex.default_rep_high, 12),
         case when v_ordinal = 1 then 180 else 120 end);
    end loop;
  end loop;

  insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
  select p_user_id, v_program, d.id,
         v_start + ((d.ordinal - 1) + (w * array_length(v_patterns, 1))) * 2
    from program_days d
    cross join generate_series(0, 1) as w
   where d.program_id = v_program
  on conflict do nothing;

  return v_program;
end $$;
