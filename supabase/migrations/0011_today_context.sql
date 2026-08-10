-- =============================================================================
-- LOAD — Today needs to know what you DID, not just what was planned
--
-- The Today card rendered the prescribed load before and after logging, so a
-- finished exercise said "40 kg · Done" — the plan, restated. On bodyweight
-- work the prescription is 0, so a hard set of pull-ups read "0 kg · Done".
--
-- Everything the screen needs now comes from one call:
--   * the prescription
--   * what you did last time, as actual sets
--   * what you have logged today, as actual sets
--   * a suggested load, with its reasoning
--
-- Returning it as one jsonb document is deliberate. The client previously
-- tracked logged sets in a local map keyed by position in the plan, which is
-- why sets logged through chat never lit up the Today cards, and why the two
-- logging paths could disagree about the same day.
-- =============================================================================

-- "Today" always means the lifter's local day, never the server's.
create or replace function user_today(p_user_id uuid)
returns date
language sql stable as $$
  select (now() at time zone
          coalesce((select timezone from profiles where id = p_user_id), 'UTC'))::date
$$;

grant execute on function user_today(uuid) to authenticated;


-- ── protein target ──────────────────────────────────────────────────────
-- Was `currentWeightKg * 1.8`, hardcoded in Dart, identical for every goal.
-- That is wrong in the case that matters most: a deficit is catabolic, so
-- cutting needs MORE protein per kg, not the same.
--
-- The basis is capped when current bodyweight is far above target — 1.8 g/kg
-- of 120 kg is 216 g, a number nobody will hit and nobody needs.
create or replace function protein_target_for(p_user_id uuid)
returns table (grams int, basis_kg numeric, per_kg numeric, rationale text)
language plpgsql stable security invoker as $$
declare
  v_goal   training_goal;
  v_target numeric;
  v_now    numeric;
  v_basis  numeric;
  v_rate   numeric;
begin
  select goal, target_weight_kg into v_goal, v_target
    from training_profiles
   where user_id = p_user_id and valid_to is null;

  select weight_kg into v_now
    from body_measurements
   where user_id = p_user_id and weight_kg is not null
   order by measured_on desc limit 1;

  if v_now is null then
    return query select 120, null::numeric, null::numeric,
      'No weigh-in yet — 120 g is a placeholder until you log one.'::text;
    return;
  end if;

  v_rate := case v_goal
    when 'lose_fat'       then 2.2   -- preserve muscle in a deficit
    when 'recomposition'  then 2.0
    when 'build_muscle'   then 1.8
    when 'strength'       then 1.8
    when 'general_health' then 1.6
    else 1.8
  end;

  -- Cap the basis at 15% above goal weight so a large gap doesn't inflate it.
  v_basis := v_now;
  if v_target is not null and v_now > v_target * 1.15 then
    v_basis := round(v_target * 1.15, 1);
  end if;

  return query select
    round(v_basis * v_rate)::int,
    v_basis,
    v_rate,
    format('%s g/kg × %s kg%s — %s.',
      v_rate, v_basis,
      case when v_basis < v_now then ' (capped near your goal weight)' else '' end,
      case v_goal
        when 'lose_fat'       then 'higher while cutting, to hold onto muscle'
        when 'recomposition'  then 'higher while recomposing'
        when 'build_muscle'   then 'the standard range for building muscle'
        when 'strength'       then 'the standard range for strength work'
        when 'general_health' then 'a maintenance intake'
        else 'a general recommendation'
      end)::text;
end $$;

grant execute on function protein_target_for(uuid) to authenticated;

-- Persist it, so the versioned table stops disagreeing with the client.
create or replace function sync_protein_target(p_user_id uuid)
returns int
language plpgsql security invoker as $$
declare v_g int; v_cur int;
begin
  select grams into v_g from protein_target_for(p_user_id);
  if v_g is null then return null; end if;

  select protein_g into v_cur from nutrition_targets
   where user_id = p_user_id and valid_to is null;

  if v_cur is null then
    insert into nutrition_targets (user_id, protein_g) values (p_user_id, v_g);
  elsif v_cur <> v_g then
    update nutrition_targets set valid_to = current_date
     where user_id = p_user_id and valid_to is null;
    insert into nutrition_targets (user_id, protein_g) values (p_user_id, v_g);
  end if;
  return v_g;
end $$;

grant execute on function sync_protein_target(uuid) to authenticated;


-- ── bodyweight, smoothed ────────────────────────────────────────────────
-- Day-to-day bodyweight swings ±1–2 kg on water and food alone. Showing the
-- most recent reading as "your weight" presents noise as fact, so the trend
-- is a 7-day trailing mean and deltas compare means, not points.
create or replace view v_bodyweight_trend
with (security_invoker = true) as
select user_id,
       measured_on,
       weight_kg as raw_kg,
       round(avg(weight_kg) over (
         partition by user_id order by measured_on
         range between interval '6 days' preceding and current row
       ), 2) as avg_7d,
       count(*) over (
         partition by user_id order by measured_on
         range between interval '6 days' preceding and current row
       ) as samples_7d
  from body_measurements
 where weight_kg is not null;


-- ── everything the Today screen renders ─────────────────────────────────
create or replace function today_plan(p_user_id uuid)
returns jsonb
language plpgsql stable security invoker as $$
declare
  v_today   date := user_today(p_user_id);
  v_program uuid;
  v_day     uuid;
  v_label   text;
  v_session uuid;
  v_status  text;
  v_items   jsonb;
begin
  select id into v_program
    from programs where user_id = p_user_id and status = 'active';

  if v_program is null then
    return jsonb_build_object('has_plan', false, 'exercises', '[]'::jsonb);
  end if;

  -- Today's slot, else the next pending one, else the start of the rotation.
  -- The rotation advances when you train; a skipped calendar day is not a
  -- failure and does not strand you on a session you already did.
  select program_day_id into v_day from scheduled_workouts
   where user_id = p_user_id and program_id = v_program and scheduled_for = v_today
   limit 1;
  if v_day is null then
    select program_day_id into v_day from scheduled_workouts
     where user_id = p_user_id and program_id = v_program
       and status = 'pending' and scheduled_for >= v_today
     order by scheduled_for limit 1;
  end if;
  if v_day is null then
    select id into v_day from program_days
     where program_id = v_program order by ordinal limit 1;
  end if;

  select label into v_label from program_days where id = v_day;

  -- One session per local day, whichever door the sets came through.
  select id, status::text into v_session, v_status
    from workout_sessions
   where user_id = p_user_id and performed_on = v_today
   order by started_at desc limit 1;

  with plan as (
    select pde.ordinal, pde.sets_target, pde.rep_low, pde.rep_high,
           pde.target_weight_kg, pde.rest_seconds,
           e.id as exercise_id, e.name, e.load_type::text as load_type
      from program_day_exercises pde
      join exercises e on e.id = pde.exercise_id
     where pde.program_day_id = v_day
  ),
  -- Most recent completed session per exercise, before today.
  prev as (
    select exercise_id, performed_on, sets, volume_kg, total_reps
      from (
        select se.exercise_id,
               ws.performed_on,
               jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps)
                         order by ss.set_number) as sets,
               sum(ss.volume_kg)                 as volume_kg,
               sum(ss.reps)                      as total_reps,
               row_number() over (partition by se.exercise_id
                                  order by ws.performed_on desc) as rn
          from session_sets ss
          join session_exercises se on se.id = ss.session_exercise_id
          join workout_sessions  ws on ws.id = se.session_id
         where se.user_id = p_user_id
           and ws.performed_on < v_today
           and ws.status = 'completed'
           and ss.is_completed
         group by se.exercise_id, ws.performed_on
      ) ranked
     where rn = 1
  ),
  -- What has been logged today, regardless of which path wrote it.
  today_sets as (
    select se.exercise_id,
           jsonb_agg(jsonb_build_array(ss.weight_kg, ss.reps)
                     order by ss.set_number) as sets,
           count(*)          as set_count,
           sum(ss.volume_kg) as volume_kg,
           sum(ss.reps)      as total_reps
      from session_sets ss
      join session_exercises se on se.id = ss.session_exercise_id
     where se.user_id = p_user_id
       and se.session_id = v_session
       and ss.is_completed
     group by se.exercise_id
  )
  select jsonb_agg(
    jsonb_build_object(
      'exercise_id',   p.exercise_id,
      'name',          p.name,
      'load_type',     p.load_type,
      'ordinal',       p.ordinal,
      'sets_target',   p.sets_target,
      'rep_low',       p.rep_low,
      'rep_high',      p.rep_high,
      'rest_seconds',  p.rest_seconds,
      -- Prefill: what they actually used last time, never a pre-progressed
      -- number. Being told you should be stronger than you are, on every set,
      -- is worse than one extra tap.
      'prefill_kg',    coalesce((prev.sets -> -1 -> 0)::numeric, p.target_weight_kg, 0),
      'prefill_reps',  coalesce(p.rep_high, 10),
      'joints',        coalesce((select jsonb_agg(j.slug)
                                   from exercise_joints ej join joints j on j.id = ej.joint_id
                                  where ej.exercise_id = p.exercise_id), '[]'::jsonb),
      'cues',          coalesce((select jsonb_agg(c.body order by c.position)
                                   from exercise_cues c where c.exercise_id = p.exercise_id), '[]'::jsonb),
      'last',          case when prev.exercise_id is null then null else jsonb_build_object(
                          'date',       prev.performed_on,
                          'sets',       prev.sets,
                          'volume_kg',  prev.volume_kg,
                          'total_reps', prev.total_reps) end,
      'today',         case when t.exercise_id is null then null else jsonb_build_object(
                          'sets',       t.sets,
                          'set_count',  t.set_count,
                          'volume_kg',  t.volume_kg,
                          'total_reps', t.total_reps) end
    ) order by p.ordinal)
    into v_items
    from plan p
    left join prev on prev.exercise_id = p.exercise_id
    left join today_sets t on t.exercise_id = p.exercise_id;

  return jsonb_build_object(
    'has_plan',       true,
    'local_date',     v_today,
    'program_day_id', v_day,
    'label',          v_label,
    'session_id',     v_session,
    'session_status', v_status,
    'exercises',      coalesce(v_items, '[]'::jsonb)
  );
end $$;

grant execute on function today_plan(uuid) to authenticated;


-- ── one session per local day ───────────────────────────────────────────
-- Both logging paths call this. Previously the Today screen created a session
-- and chat logging created a second one called "Logged from chat" whenever no
-- session happened to be open, which double-counted the day in history and in
-- the streak, and named a session after its input method.
create or replace function open_session_for_today(p_user_id uuid, p_title text default null)
returns uuid
language plpgsql security invoker as $$
declare
  v_today date := user_today(p_user_id);
  v_id    uuid;
  v_day   uuid;
  v_label text;
begin
  select id into v_id from workout_sessions
   where user_id = p_user_id and performed_on = v_today
   order by started_at desc limit 1;
  if v_id is not null then return v_id; end if;

  select (today_plan(p_user_id) ->> 'program_day_id')::uuid into v_day;
  select label into v_label from program_days where id = v_day;

  insert into workout_sessions (user_id, program_day_id, title, performed_on, status)
  values (p_user_id, v_day, coalesce(p_title, v_label, 'Training'), v_today, 'in_progress')
  returning id into v_id;

  return v_id;
end $$;

grant execute on function open_session_for_today(uuid, text) to authenticated;
