-- =============================================================================
-- LOAD v2 — lift status: stalled / progressing / no_change
--
-- Implements decision D5 (docs/08 §4, decided 2026-08-13):
--
--   STALLED = top-set load unchanged across >= 3 consecutive sessions of the
--   lift, AND the top of the rep range completed in >= 2 of those sessions.
--
-- The second condition is what separates "stuck" from "still earning it": a
-- lifter sitting at 60 kg who has not yet hit 5x8 is progressing through the
-- rep range, not stalled at the load. Both parameters are function arguments
-- with defaults, so tuning the rule is a redeploy of one function, never a
-- client release.
--
-- One function serves two Progress panels: the per-session e1RM series it
-- returns is exactly the sparkline panel 1 draws, and the classification is
-- panel 2. It also backs the trainer's stall receipts ("15 sets read · 5
-- weeks") — same numbers, same source.
-- =============================================================================

create or replace function lift_status(
  p_user_id        uuid,
  p_since          date default null,       -- range control; null = all time
  p_stall_sessions int  default 3,          -- D5 parameter N
  p_top_hits       int  default 2           -- D5 parameter: top-of-range count
)
returns table (
  exercise_id      uuid,
  exercise_name    text,
  sessions_counted bigint,
  latest_top_kg    numeric,
  latest_e1rm_kg   numeric,
  -- Consecutive most-recent sessions at latest_top_kg, and how many of those
  -- finished the top of the rep range. The trainer's copy is composed from
  -- these ("5 sessions at 60 kg, top of the range three times").
  streak_sessions  bigint,
  streak_top_hits  bigint,
  net_change_kg    numeric,                 -- latest vs earliest in window
  first_session_on date,
  latest_session_on date,
  status           text,                    -- insufficient | stalled | progressing | no_change
  -- Oldest-first [{on, top_kg, e1rm}] — the stepped sparkline, drawn as-is.
  series           jsonb
)
language sql stable security invoker as $$
  with raw_sets as (
    select se.exercise_id,
           ws.performed_on,
           ss.weight_kg,
           ss.reps,
           ss.e1rm_kg,
           -- Top-of-range threshold: prescription via the program link,
           -- falling back to the catalog default for ad-hoc work.
           coalesce(pde.rep_high, e.default_rep_high, 9999) as rep_top,
           max(ss.weight_kg) over (partition by se.exercise_id, ws.performed_on)
             as sess_top_kg
      from session_sets ss
      join session_exercises se on se.id = ss.session_exercise_id
      join workout_sessions  ws on ws.id = se.session_id
      join exercises         e  on e.id  = se.exercise_id
      left join program_day_exercises pde on pde.id = se.program_day_exercise_id
     where se.user_id = p_user_id
       and ws.status = 'completed'
       and ss.is_completed
       and ss.kind = 'working'
       and ss.weight_kg is not null          -- weighted lifts only
       and (p_since is null or ws.performed_on >= p_since)
  ),
  per_session as (
    -- One row per (exercise, session): the top working set and whether any
    -- set AT that top weight reached the top of the prescribed range.
    select exercise_id,
           performed_on,
           max(weight_kg) as top_kg,
           max(e1rm_kg)   as e1rm_kg,
           bool_or(weight_kg = sess_top_kg and reps >= rep_top) as hit_top
      from raw_sets
     group by exercise_id, performed_on
  ),
  ranked as (
    select ps.*,
           row_number() over (partition by ps.exercise_id
                              order by ps.performed_on desc) as rn_desc,
           first_value(ps.top_kg) over (partition by ps.exercise_id
                                        order by ps.performed_on desc) as latest_kg
      from per_session ps
  ),
  streaks as (
    -- The streak ends at the first (most recent going backwards) session
    -- whose top load differs from the latest.
    select exercise_id,
           coalesce(min(rn_desc) filter (where top_kg is distinct from latest_kg) - 1,
                    count(*)) as streak_len
      from ranked
     group by exercise_id
  ),
  agg as (
    select r.exercise_id,
           count(*)                                        as n_sessions,
           max(r.latest_kg)                                as latest_top_kg,
           (array_agg(r.e1rm_kg order by r.rn_desc))[1]    as latest_e1rm,
           s.streak_len,
           count(*) filter (where r.rn_desc <= s.streak_len
                              and r.hit_top)               as streak_hits,
           (array_agg(r.top_kg order by r.rn_desc))[1]
             - (array_agg(r.top_kg order by r.performed_on))[1] as net_change,
           min(r.performed_on)                             as first_on,
           max(r.performed_on)                             as latest_on,
           jsonb_agg(jsonb_build_object(
             'on', r.performed_on, 'top_kg', r.top_kg, 'e1rm', r.e1rm_kg)
             order by r.performed_on)                      as series
      from ranked r
      join streaks s using (exercise_id)
     group by r.exercise_id, s.streak_len
  )
  select a.exercise_id,
         e.name,
         a.n_sessions,
         a.latest_top_kg,
         a.latest_e1rm,
         a.streak_len,
         a.streak_hits,
         a.net_change,
         a.first_on,
         a.latest_on,
         case
           when a.n_sessions < p_stall_sessions                    then 'insufficient'
           -- Stalled wins over progressing: three flat sessions at the top of
           -- the range is stuck NOW, whatever happened earlier in the window.
           when a.streak_len >= p_stall_sessions
            and a.streak_hits >= p_top_hits                        then 'stalled'
           when a.net_change > 0                                   then 'progressing'
           else                                                         'no_change'
         end,
         a.series
    from agg a
    join exercises e on e.id = a.exercise_id
   order by case
              when a.n_sessions < p_stall_sessions then 3
              when a.streak_len >= p_stall_sessions
               and a.streak_hits >= p_top_hits then 0        -- stalled first
              when a.net_change <= 0 then 1                  -- then no_change
              else 2                                          -- fine last
            end,
            a.latest_on desc;
$$;

grant execute on function lift_status(uuid, date, int, int) to authenticated;

comment on function lift_status(uuid, date, int, int) is
  'Per weighted lift: e1RM/top-load series plus stalled/progressing/no_change '
  'classification (D5: unchanged load >= p_stall_sessions with top-of-range in '
  '>= p_top_hits of them). Serves Progress panels 1 and 2 and trainer receipts.';
