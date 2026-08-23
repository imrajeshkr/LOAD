-- =============================================================================
-- v2_0035 — the generator applies standing swaps after rebuilding
--
-- Without this, spec §9's "survives regeneration" is false: bootstrap_user_program
-- rebuilds program_days from scratch, so a swapped lift silently reverts the
-- next time the plan changes shape. v2_0034 stores the preference; this is
-- what honours it.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bootstrap_user_program(p_user_id uuid, p_bench_start_kg numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tp          training_profiles%rowtype;
  v_env         train_environment;
  v_exp         experience_level;
  v_goal        training_goal;
  v_split       split_type;
  v_program     uuid;
  v_day         uuid;
  v_cycle       text[];        -- pattern set per day-type, from the split
  v_cyclelabel  text[];
  v_daysets     text[];        -- pattern set per actual training day
  v_labels      text[];
  v_pats        text[];        -- patterns of the day being filled
  v_i           int;
  v_slot_i      int;
  v_slots       int;
  v_ex          record;
  v_ordinal     int;
  v_start       date := current_date;
  v_daycount    int;
  v_weekdays    smallint[];
  v_is_bench    boolean;
  v_kg          numeric;
  v_is_barbell  boolean;
  v_has_history boolean;
  v_slot        int := 0;
  v_wd          smallint;
  v_day_ids     uuid[];
  v_used        uuid[] := '{}'; -- placed anywhere this program — soft penalty
  v_used_today  uuid[];         -- placed in the day being filled — hard block
  v_musc_today  uuid[];         -- muscles already anchored in the day
  v_musc        record;
  v_first       boolean;
  v_target      int;
  v_rx          record;
  v_sets        int;
  v_rest        int;
  v_cyclelen    int;
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
  -- goals[] preserves the order the user picked them; the first leads.
  v_goal     := coalesce(v_tp.goals[1], v_tp.goal, 'build_muscle');
  v_weekdays := coalesce(v_tp.training_weekdays, '{}');
  v_daycount := coalesce(nullif(cardinality(v_weekdays), 0), v_tp.days_per_week, 3);
  v_daycount := greatest(2, least(6, v_daycount));

  if v_tp.split_preference is not null and v_tp.split_preference <> 'no_preference' then
    v_split := v_tp.split_preference;
  elsif v_daycount <= 3 then v_split := 'full_body';
  elsif v_daycount <= 5 then v_split := 'upper_lower';
  else                       v_split := 'push_pull_legs';
  end if;

  v_target := plan_weekly_sets(v_exp, v_goal);
  select * into v_rx from plan_goal_prescription(v_goal);

  update programs set status = 'archived'
   where user_id = p_user_id and status = 'active';

  -- Day types for the split. `core` rides with the lower/leg day so abs get
  -- trained without stealing a slot from a pressing or pulling day.
  case v_split
    when 'push_pull_legs' then
      v_cycle      := array['push', 'pull', 'legs,core'];
      v_cyclelabel := array['Push day', 'Pull day', 'Leg day'];
    when 'upper_lower' then
      v_cycle      := array['push,pull', 'legs,core'];
      v_cyclelabel := array['Upper body', 'Lower body'];
    else
      v_cycle      := array['push,pull,legs,core'];
      v_cyclelabel := array['Full body'];
  end case;
  v_cyclelen := array_length(v_cycle, 1);

  -- One program_day per training day. When the cycle repeats within the week
  -- the labels get A/B/C suffixes, so "Upper body A" and "Upper body B" are
  -- visibly different sessions rather than the same day shown twice.
  v_daysets := '{}'; v_labels := '{}';
  for v_i in 1 .. v_daycount loop
    v_daysets := array_append(v_daysets, v_cycle[((v_i - 1) % v_cyclelen) + 1]);
    v_labels  := array_append(
      v_labels,
      v_cyclelabel[((v_i - 1) % v_cyclelen) + 1]
      || case when v_daycount > v_cyclelen
              then ' ' || chr(65 + ((v_i - 1) / v_cyclelen)::int)
              else '' end);
  end loop;

  insert into programs (user_id, name, goal, split, days_per_week, status,
                        authored_by, starts_on)
  values (p_user_id, initcap(replace(v_split::text, '_', ' ')),
          v_goal, v_split, v_daycount, 'active', 'coach_ai', v_start)
  returning id into v_program;

  -- ── Candidate pool: Core only, filtered by the things that are not
  -- negotiable — availability, training age, and joint safety. Everything
  -- softer than that is handled by scoring below.
  create temp table if not exists _cand (
    exercise_id uuid, slug text, muscle_id uuid, pattern text,
    mechanic text, min_experience experience_level,
    default_start_kg numeric, uses_barbell boolean
  ) on commit drop;
  delete from _cand;

  insert into _cand
  select e.id, e.slug, em.muscle_id, e.pattern::text, e.mechanic, e.min_experience,
         e.default_start_kg,
         exists (select 1 from exercise_equipment ee
                   join equipment q on q.id = ee.equipment_id
                  where ee.exercise_id = e.id and q.slug = 'barbell')
    from exercises e
    join exercise_muscles em on em.exercise_id = e.id and em.role = 'primary'
   where e.owner_id is null
     and e.is_core
     and e.load_type in ('weight_reps', 'bodyweight_reps')
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
            where ej.exercise_id = e.id and ej.stress_level = 'severe');

  -- Buffer for the day being assembled, drained into program_day_exercises
  -- once the whole day is known and can be sequenced.
  create temp table if not exists _dayplan (
    pick_seq int, exercise_id uuid, mechanic text, uses_barbell boolean,
    sets_target int, rep_low int, rep_high int,
    target_weight_kg numeric, rest_seconds int
  ) on commit drop;

  -- ── Stage 1: the weekly budget, one row per muscle we can actually train.
  create temp table if not exists _budget (
    muscle_id uuid primary key, pattern text, remaining numeric
  ) on commit drop;
  delete from _budget;

  insert into _budget
  select muscle_id, min(pattern), v_target
    from _cand group by muscle_id;

  -- ── Stages 2-5: walk the days, always spending on the hungriest muscle.
  for v_i in 1 .. v_daycount loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i]) returning id into v_day;
    v_day_ids := array_append(v_day_ids, v_day);

    v_pats       := string_to_array(v_daysets[v_i], ',');
    v_ordinal    := 0;
    v_used_today := '{}';
    v_musc_today := '{}';
    delete from _dayplan;

    -- Session length cap (spec §6: 4-6 exercises), floored so a sparse
    -- environment still produces a real session rather than a single lift.
    select least(greatest(count(*), 3), 6) into v_slots
      from _budget where pattern = any(v_pats);

    for v_slot_i in 1 .. v_slots loop
      -- Two decisions, deliberately made separately. Sorting muscle priority
      -- and exercise quality in one ORDER BY looks tidier but is wrong: the
      -- remaining-budget key dominates, the mechanic preference goes inert,
      -- and the result is a beginner push day that opens with Bench Dips,
      -- gives Chest a single cable fly, and never prescribes Bench Press.

      -- 1 · Which muscle is hungriest. A muscle cannot take a second slot in a
      -- day until every eligible muscle has had a first one — otherwise Rear
      -- Delt collects two exercises while Rhomboids gets none.
      select b.muscle_id, b.remaining into v_musc
        from _budget b
       where b.pattern = any(v_pats)
         and (not (b.muscle_id = any(v_musc_today))
              or not exists (select 1 from _budget b2
                              where b2.pattern = any(v_pats)
                                and not (b2.muscle_id = any(v_musc_today))))
       order by b.remaining desc, b.pattern, b.muscle_id
       limit 1;
      exit when not found;
      exit when v_musc.remaining <= 0 and v_slot_i > 3;

      v_first := not (v_musc.muscle_id = any(v_musc_today));

      -- 2 · Which exercise trains it. A muscle's first lift of the day is its
      -- anchor, so compounds win there and isolation fills any later slot.
      -- Repeating a lift used earlier in the week is a penalty, never a bar:
      -- a bodyweight-only catalog holds nine lifts, and a three-day plan
      -- should repeat push-ups rather than leave a day empty.
      select c.exercise_id, c.slug, c.muscle_id, c.default_start_kg,
             c.uses_barbell, c.mechanic
        into v_ex
        from _cand c
       where c.muscle_id = v_musc.muscle_id
         and not (c.exercise_id = any(v_used_today))
       order by (case when v_first then (c.mechanic is distinct from 'compound')
                      else (c.mechanic is distinct from 'isolation') end),
                (c.exercise_id = any(v_used)),
                c.min_experience,
                c.slug
       limit 1;

      -- Every lift for this muscle is already on today's card: retire it for
      -- the day and let the next-hungriest muscle take the slot.
      if not found then
        v_musc_today := array_append(v_musc_today, v_musc.muscle_id);
        continue;
      end if;
      v_musc_today := array_append(v_musc_today, v_musc.muscle_id);

      -- Set count is a training decision, not an arithmetic one. The weekly
      -- budget decides WHICH muscle gets this slot (above); it must not also
      -- decide how many sets go in it, because dividing a 14-set target by the
      -- days that could train a muscle yields 5 sets on every exercise and a
      -- two-hour session. A week has a hard slot capacity — 3 days x 6 slots
      -- cannot deliver 14 sets to each of 13 muscles at any set count — so the
      -- budget is a priority signal and the prescription stays in the range
      -- that is actually productive per exercise.
      v_sets := case
                  when v_ex.mechanic = 'compound' and v_goal = 'strength' then 5
                  when v_ex.mechanic = 'compound' then 4
                  else 3
                end;

      v_ordinal    := v_ordinal + 1;
      v_used       := array_append(v_used, v_ex.exercise_id);
      v_used_today := array_append(v_used_today, v_ex.exercise_id);
      v_is_bench   := v_ex.slug = 'bench-press';
      v_is_barbell := v_ex.uses_barbell;

      select max(db.top_weight_kg) into v_kg
        from v_exercise_daily_bests db
       where db.user_id = p_user_id and db.exercise_id = v_ex.exercise_id;
      v_has_history := v_kg is not null;
      v_kg := coalesce(v_kg, v_ex.default_start_kg);

      if v_is_bench and p_bench_start_kg is not null then
        v_kg := p_bench_start_kg;
        v_has_history := true;
      end if;
      -- Stage 5: a lifter who has never benched starts light — empty bar on
      -- barbell work, 40% of catalog default on everything else.
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

      v_rest := case when v_ex.mechanic = 'compound'
                     then v_rx.rest_compound else v_rx.rest_isolation end;

      -- Buffered, not inserted: the order lifts are *chosen* in follows muscle
      -- hunger, which at the start of a week is an arbitrary tie-break. Writing
      -- that straight to `ordinal` opens Leg day with cable crunches and leaves
      -- Back Squat and Deadlift for a fatigued lifter at the end. Selection
      -- order and session order are different questions; the session is
      -- sequenced once the day is picked, below.
      --
      -- The 5x5 bench ramp for an uncalibrated novice overrides the goal
      -- prescription — it exists to find a working weight, not to train a rep
      -- range.
      insert into _dayplan (pick_seq, exercise_id, mechanic, uses_barbell,
                            sets_target, rep_low, rep_high, target_weight_kg,
                            rest_seconds)
      values (v_ordinal, v_ex.exercise_id, v_ex.mechanic, v_ex.uses_barbell,
              case when v_is_bench and v_tp.has_benched is false then 5 else v_sets end,
              case when v_is_bench and v_tp.has_benched is false then 5 else v_rx.rep_low end,
              case when v_is_bench and v_tp.has_benched is false then 5 else v_rx.rep_high end,
              v_kg, v_rest);

      -- Spend the budget: the primary muscle pays in full, secondaries at
      -- their contribution weight, so a compound counts toward everything it
      -- actually trains instead of being free volume.
      update _budget set remaining = remaining - v_sets
       where muscle_id = v_ex.muscle_id;

      update _budget b set remaining = b.remaining - (v_sets * em.contribution)
        from exercise_muscles em
       where em.exercise_id = v_ex.exercise_id
         and em.role = 'secondary'
         and em.muscle_id = b.muscle_id;
    end loop;

    -- Sequence the session: heavy barbell compounds first, then other
    -- compounds, then isolation — the order a coach would actually write.
    insert into program_day_exercises
      (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high,
       target_weight_kg, rest_seconds)
    select v_day, d.exercise_id,
           row_number() over (order by (d.mechanic is distinct from 'compound'),
                                       not d.uses_barbell,
                                       d.pick_seq),
           d.sets_target, d.rep_low, d.rep_high, d.target_weight_kg, d.rest_seconds
      from _dayplan d;
  end loop;

  -- ── Standing swaps (v2_0034) ──────────────────────────────────────────────
  -- The whole point of storing a swap as a preference rather than a row edit:
  -- the program was just rebuilt from scratch, and the lifter's choice has to
  -- survive that. Applied as a post-pass so selection logic stays unaware of
  -- it, and skipped where it would duplicate a lift already on that day.
  --
  -- Weight comes from the substitute's own history or catalog default, never
  -- from the lift it replaced.
  update program_day_exercises pde
     set exercise_id = s.to_exercise_id,
         target_weight_kg = snap_to_loadable(p_user_id, coalesce(
           (select max(db.top_weight_kg) from v_exercise_daily_bests db
             where db.user_id = p_user_id and db.exercise_id = s.to_exercise_id),
           (select e2.default_start_kg from exercises e2 where e2.id = s.to_exercise_id),
           pde.target_weight_kg))
    from exercise_swaps s, program_days pd
   where s.user_id = p_user_id
     and pde.program_day_id = pd.id
     and pd.program_id = v_program
     and pde.exercise_id = s.from_exercise_id
     and not exists (select 1 from program_day_exercises x
                      where x.program_day_id = pde.program_day_id
                        and x.exercise_id = s.to_exercise_id);

  -- ── Schedule (unchanged: forward-only, pattern-driven) ────────────────────
  delete from program_weekday_slots where user_id = p_user_id;
  delete from scheduled_workouts
   where user_id = p_user_id and scheduled_for >= v_start;

  if cardinality(v_weekdays) > 0 then
    v_slot := 0;
    for v_wd in select w from unnest(v_weekdays) w order by w loop
      insert into program_weekday_slots (program_id, user_id, weekday, program_day_id)
      values (v_program, p_user_id, v_wd,
              v_day_ids[(v_slot % array_length(v_day_ids, 1)) + 1]);
      v_slot := v_slot + 1;
    end loop;

    insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
    select p_user_id, v_program, s.program_day_id, d::date
      from generate_series(v_start, v_start + 34, interval '1 day') d
      join program_weekday_slots s
        on s.program_id = v_program
       and s.weekday = extract(isodow from d)::smallint
    on conflict do nothing;
  else
    insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
    select p_user_id, v_program, d.id,
           v_start + ((d.ordinal - 1) + (w * v_daycount)) * 2
      from program_days d cross join generate_series(0, 1) as w
     where d.program_id = v_program
    on conflict do nothing;
  end if;

  return v_program;
end $function$;
