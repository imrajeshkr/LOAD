-- =============================================================================
-- LOAD v2 — Progress tab aggregations
--
-- What each panel reads:
--   1 Strength tiles   → lift_status()            (v2_0008)
--   2 Where stuck      → lift_status()            (v2_0008)
--   3 Effort histogram → effort_histogram()       (here)
--   4 Sets per muscle  → weekly_sets_by_muscle()  (v2_0007)
--   5 Body / protein   → v_bodyweight_trend, v_nutrition_daily (existing)
--   6 Showing up       → consistency_weeks()      (here)
--   7 Photos           → progress_photo_pair()    (v2_0005)
--   gates (all panels) → progress_gates()         (here)
--
-- Every range-sensitive function takes p_since, driven by the 8wk/12wk/6mo/All
-- control. Gate thresholds live in the CLIENT copy ("seven weigh-ins and the
-- average starts to mean something") — the DB returns raw counts so the copy
-- can change without a migration.
-- =============================================================================

-- ── panel 3: effort histogram ───────────────────────────────────────────
-- Buckets 0..6, where 6 means "6 or more". Working sets with an answer only —
-- the design's gate counts answered sets, not all sets.
create or replace function effort_histogram(p_user_id uuid, p_since date default null)
returns table (rir_bucket int, set_count bigint)
language sql stable security invoker as $$
  select least(ss.rir, 6) as rir_bucket, count(*) as set_count
    from session_sets ss
    join session_exercises se on se.id = ss.session_exercise_id
    join workout_sessions  ws on ws.id = se.session_id
   where se.user_id = p_user_id
     and ws.status = 'completed'
     and ss.is_completed
     and ss.kind = 'working'
     and ss.rir is not null
     and (p_since is null or ws.performed_on >= p_since)
   group by least(ss.rir, 6)
   order by rir_bucket;
$$;

grant execute on function effort_histogram(uuid, date) to authenticated;

-- ── panel 6: sessions per week vs target ────────────────────────────────
-- One row per ISO week. paused_days lets the client drop fully-paused weeks
-- from the rate ("weeks off don't count against you") and dim partial ones.
create or replace function consistency_weeks(p_user_id uuid, p_since date default null)
returns table (
  week_start    date,
  session_count bigint,
  paused_days   int,
  target        int
)
language sql stable security invoker as $$
  with target as (
    select coalesce(
             nullif(cardinality(tp.training_weekdays), 0),
             (select p.days_per_week from programs p
               where p.user_id = p_user_id and p.status = 'active'),
             3) as t
      from training_profiles tp
     where tp.user_id = p_user_id and tp.valid_to is null
  ),
  bounds as (
    select date_trunc('week', coalesce(p_since,
             (select min(performed_on) from workout_sessions
               where user_id = p_user_id and status = 'completed')))::date as w0,
           date_trunc('week', user_today(p_user_id))::date as w1
  ),
  weeks as (
    select generate_series((select w0 from bounds), (select w1 from bounds),
                           interval '7 days')::date as week_start
  )
  select w.week_start,
         (select count(*) from workout_sessions ws
           where ws.user_id = p_user_id and ws.status = 'completed'
             and ws.performed_on >= w.week_start
             and ws.performed_on <  w.week_start + 7),
         paused_days_between(p_user_id, w.week_start, w.week_start + 6),
         (select t from target)
    from weeks w
   where (select w0 from bounds) is not null
   order by w.week_start;
$$;

grant execute on function consistency_weeks(uuid, date) to authenticated;

-- ── data-sufficiency gates ──────────────────────────────────────────────
-- Raw counts; the client compares against per-panel thresholds (3 sessions
-- per lift, 8 answered sets, 7 weigh-ins, 3 weeks, 1 full week).
create or replace function progress_gates(p_user_id uuid)
returns jsonb
language sql stable security invoker as $$
  select jsonb_build_object(
    'sessions_total',    (select count(*) from workout_sessions
                           where user_id = p_user_id and status = 'completed'),
    'weeks_of_history',  (select count(distinct date_trunc('week', performed_on))
                            from workout_sessions
                           where user_id = p_user_id and status = 'completed'),
    'max_lift_sessions', coalesce((select max(n) from (
                            select count(distinct ws.performed_on) as n
                              from session_exercises se
                              join workout_sessions ws on ws.id = se.session_id
                             where se.user_id = p_user_id and ws.status = 'completed'
                             group by se.exercise_id) x), 0),
    'rir_answered_sets', (select count(*) from session_sets ss
                            join session_exercises se on se.id = ss.session_exercise_id
                           where se.user_id = p_user_id
                             and ss.rir is not null and ss.kind = 'working'),
    'weigh_ins',         (select count(*) from body_measurements
                           where user_id = p_user_id and weight_kg is not null),
    'protein_days',      (select count(distinct logged_on) from nutrition_entries
                           where user_id = p_user_id),
    'photo_count',       (select count(*) from progress_photos
                           where user_id = p_user_id)
  );
$$;

grant execute on function progress_gates(uuid) to authenticated;
