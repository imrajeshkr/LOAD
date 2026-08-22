-- =============================================================================
-- v2_0016 — persistent scheduling model + calendar day swap (#4, Option B)
--
--   * program_weekday_slots: the permanent weekday -> session pattern.
--   * bootstrap_user_program writes the slots and materialises a 35-day window.
--   * ensure_my_schedule(): rolling top-up so the calendar never runs out.
--   * swap_scheduled_days(): drag-drop reorder, this-week or every-week.
--   * Backfill slots for existing active programs so live accounts keep working.
--
-- train_screen is untouched — it already reads each date's label from
-- scheduled_workouts; the pattern just makes those rows correct and endless.
-- =============================================================================

-- ── the pattern ──────────────────────────────────────────────────────────
create table if not exists program_weekday_slots (
  program_id     uuid not null,
  user_id        uuid not null,
  weekday        smallint not null check (weekday between 1 and 7),
  program_day_id uuid not null,
  created_at     timestamptz not null default now(),
  primary key (program_id, weekday),
  foreign key (program_id, user_id)        references programs(id, user_id) on delete cascade,
  foreign key (program_day_id, program_id) references program_days(id, program_id) on delete cascade
);

comment on table program_weekday_slots is
  'The permanent weekday -> program_day pattern for a program. scheduled_workouts '
  'are materialised from this over a rolling 35-day window (ensure_my_schedule).';

alter table program_weekday_slots enable row level security;

drop policy if exists program_weekday_slots_own on program_weekday_slots;
create policy program_weekday_slots_own on program_weekday_slots
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ── generator: writes slots, then materialises 35 days from them ───────────
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
           v_start + ((d.ordinal - 1) + (w * array_length(v_patterns, 1))) * 2
      from program_days d cross join generate_series(0, 1) as w
     where d.program_id = v_program
    on conflict do nothing;
  end if;

  return v_program;
end $$;

revoke all on function bootstrap_user_program(uuid, numeric) from public;
grant execute on function bootstrap_user_program(uuid, numeric) to authenticated;

-- ── rolling top-up ─────────────────────────────────────────────────────────
-- Keeps scheduled_workouts filled from today through today+34 for the caller's
-- active program, following the pattern. One row per date (won't add a second
-- if a date already has one). Called fire-and-forget by the client on load.
create or replace function ensure_my_schedule()
returns void
language plpgsql security invoker as $$
declare
  v_uid   uuid := auth.uid();
  v_prog  uuid;
  v_today date;
begin
  if v_uid is null then return; end if;
  v_today := user_today(v_uid);
  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then return; end if;

  insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
  select v_uid, v_prog, s.program_day_id, d::date
    from generate_series(v_today, v_today + 34, interval '1 day') d
    join program_weekday_slots s
      on s.program_id = v_prog
     and s.weekday = extract(isodow from d)::smallint
   where not exists (select 1 from scheduled_workouts sw
                      where sw.user_id = v_uid and sw.scheduled_for = d::date)
  on conflict do nothing;
end $$;

grant execute on function ensure_my_schedule() to authenticated;

-- ── the swap ────────────────────────────────────────────────────────────────
-- Reorder the split by exchanging two training days. Forward-only.
--   scope 'week'    — swap just those two dated rows.
--   scope 'forever' — swap the weekday pattern, then rewrite all future rows on
--                     those two weekdays. Undo = call again with args swapped.
create or replace function swap_scheduled_days(
  p_from  date,
  p_to    date,
  p_scope text
)
returns void
language plpgsql security invoker as $$
declare
  v_uid     uuid := auth.uid();
  v_prog    uuid;
  v_today   date;
  v_from_pd uuid;
  v_to_pd   uuid;
  v_wf      smallint;
  v_wt      smallint;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  v_today := user_today(v_uid);
  if p_from < v_today or p_to < v_today then
    raise exception 'can only rearrange today or later';
  end if;
  if p_from = p_to then return; end if;

  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then raise exception 'no active program'; end if;

  select program_day_id into v_from_pd
    from scheduled_workouts where user_id = v_uid and scheduled_for = p_from;
  select program_day_id into v_to_pd
    from scheduled_workouts where user_id = v_uid and scheduled_for = p_to;
  if v_from_pd is null or v_to_pd is null then
    raise exception 'both days must be training days';
  end if;

  if p_scope = 'week' then
    update scheduled_workouts set program_day_id = v_to_pd
     where user_id = v_uid and scheduled_for = p_from;
    update scheduled_workouts set program_day_id = v_from_pd
     where user_id = v_uid and scheduled_for = p_to;

  elsif p_scope = 'forever' then
    v_wf := extract(isodow from p_from)::smallint;
    v_wt := extract(isodow from p_to)::smallint;

    update program_weekday_slots set program_day_id = v_to_pd
     where program_id = v_prog and weekday = v_wf;
    update program_weekday_slots set program_day_id = v_from_pd
     where program_id = v_prog and weekday = v_wt;

    update scheduled_workouts set program_day_id = v_to_pd
     where user_id = v_uid and scheduled_for >= v_today
       and extract(isodow from scheduled_for)::smallint = v_wf;
    update scheduled_workouts set program_day_id = v_from_pd
     where user_id = v_uid and scheduled_for >= v_today
       and extract(isodow from scheduled_for)::smallint = v_wt;
  else
    raise exception 'bad scope %', p_scope;
  end if;
end $$;

grant execute on function swap_scheduled_days(date, date, text) to authenticated;

-- ── backfill: give existing active programs a pattern from their schedule ────
-- Per (program, weekday), take the earliest upcoming scheduled row's day.
insert into program_weekday_slots (program_id, user_id, weekday, program_day_id)
select distinct on (p.id, extract(isodow from sw.scheduled_for))
       p.id, p.user_id,
       extract(isodow from sw.scheduled_for)::smallint, sw.program_day_id
  from programs p
  join scheduled_workouts sw
    on sw.program_id = p.id and sw.user_id = p.user_id
 where p.status = 'active'
   and sw.scheduled_for >= current_date
   and not exists (select 1 from program_weekday_slots s where s.program_id = p.id)
 order by p.id, extract(isodow from sw.scheduled_for), sw.scheduled_for
on conflict do nothing;
