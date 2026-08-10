-- =============================================================================
-- LOAD — starting loads in the catalog
--
-- A generated program had no working weight for any movement the lifter had
-- never logged, so the Today screen showed "0 kg" — which reads as broken and
-- is useless as a starting point. The old app carried hardcoded starting
-- weights (Bench 60, OHP 30, Incline DB 18, Pushdown 16); this puts that same
-- knowledge in the catalog, where it belongs and where it covers all 36
-- movements instead of four.
--
-- Values are conservative intermediate loads. They are a starting point only:
-- once a lifter has logged a movement, bootstrap prefers their actual top set.
-- Zero is correct for bodyweight movements — there is no external load.
-- =============================================================================

alter table exercises
  add column if not exists default_start_kg numeric(6,2);

update exercises e set default_start_kg = v.kg
  from (values
    -- push
    ('bench-press',60),('incline-db-press',20),('overhead-press',35),
    ('db-bench-press',22),('machine-chest-press',40),('cable-fly',12),
    ('tricep-pushdown',20),('overhead-tricep-ext',15),('lateral-raise',8),
    ('floor-press',50),('landmine-press',25),('push-up',0),
    -- pull
    ('barbell-row',50),('pull-up',0),('lat-pulldown',45),
    ('seated-cable-row',45),('dumbbell-row',24),('chest-supported-row',40),
    ('face-pull',15),('barbell-curl',25),('hammer-curl',12),
    -- legs
    ('back-squat',70),('front-squat',45),('deadlift',90),
    ('romanian-deadlift',60),('leg-press',100),('leg-curl',35),
    ('leg-extension',35),('bulgarian-split-squat',16),('walking-lunge',16),
    ('hip-thrust',60),('goblet-squat',20),('calf-raise',50),
    -- core
    ('plank',0),('hanging-leg-raise',0),('cable-crunch',25)
  ) as v(slug, kg)
 where e.slug = v.slug and e.owner_id is null;

-- Prefer what they have actually lifted; fall back to the catalog default.
create or replace function bootstrap_user_program(p_user_id uuid)
returns uuid
language plpgsql
security definer set search_path = public as $$
declare
  v_tp       training_profiles%rowtype;
  v_program  uuid;
  v_day      uuid;
  v_patterns text[];
  v_labels   text[];
  v_i        int;
  v_ex       record;
  v_ordinal  int;
  v_start    date := current_date;
begin
  select * into v_tp from training_profiles
   where user_id = p_user_id and valid_to is null;
  if not found then
    raise exception 'no current training profile for user %', p_user_id;
  end if;

  update programs set status = 'archived'
   where user_id = p_user_id and status = 'active';

  case v_tp.split_preference
    when 'push_pull_legs' then
      v_patterns := array['push','pull','legs'];
      v_labels   := array['Push Day','Pull Day','Leg Day'];
    when 'upper_lower' then
      v_patterns := array['push','legs'];
      v_labels   := array['Upper Day','Lower Day'];
    when 'full_body' then
      v_patterns := array['push'];
      v_labels   := array['Full Body'];
    else
      v_patterns := array['push','pull','legs'];
      v_labels   := array['Push Day','Pull Day','Leg Day'];
  end case;

  insert into programs (user_id, name, goal, split, days_per_week, status, authored_by, starts_on)
  values (p_user_id, initcap(replace(v_tp.split_preference::text,'_',' ')),
          v_tp.goal, v_tp.split_preference, v_tp.days_per_week, 'active', 'template', v_start)
  returning id into v_program;

  for v_i in 1 .. array_length(v_patterns,1) loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i]) returning id into v_day;

    v_ordinal := 0;
    for v_ex in
      with candidates as (
        select e.id, e.name, e.default_rep_low, e.default_rep_high,
               e.default_start_kg, em.muscle_id
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
                             and env.environment = v_tp.environment))
           and not exists (
                 select 1 from exercise_joints ej
                   join user_constraints uc
                     on uc.joint_id = ej.joint_id and uc.user_id = p_user_id
                    and uc.active_to is null
                  where ej.exercise_id = e.id and ej.stress_level = 'severe')
      ),
      best_per_muscle as (
        select distinct on (muscle_id) id, name, default_rep_low, default_rep_high, default_start_kg
          from candidates
         order by muscle_id, default_rep_low nulls last, name
      )
      select b.id, b.default_rep_low, b.default_rep_high,
             coalesce(
               (select max(db.top_weight_kg)
                  from v_exercise_daily_bests db
                 where db.user_id = p_user_id and db.exercise_id = b.id),
               b.default_start_kg
             ) as start_kg
        from best_per_muscle b
       order by b.default_rep_low nulls last, b.name
       limit 4
    loop
      v_ordinal := v_ordinal + 1;
      insert into program_day_exercises
        (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high,
         target_weight_kg, rest_seconds)
      values
        (v_day, v_ex.id, v_ordinal,
         case when v_ordinal = 1 then 4 else 3 end,
         coalesce(v_ex.default_rep_low, 8),
         coalesce(v_ex.default_rep_high, 12),
         v_ex.start_kg,
         case when v_ordinal = 1 then 180 else 120 end);
    end loop;
  end loop;

  insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
  select p_user_id, v_program, d.id,
         v_start + ((d.ordinal - 1) + (w * array_length(v_patterns,1))) * 2
    from program_days d cross join generate_series(0,1) as w
   where d.program_id = v_program
  on conflict do nothing;

  return v_program;
end $$;
