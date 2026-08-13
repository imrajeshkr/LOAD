-- =============================================================================
-- LOAD v2 — muscle display groups
--
-- Progress panel 4 ("Is anything neglected?") shows six bars:
--   Chest · Back · Quads · Hamstrings · Shoulders · Arms
--
-- The schema's muscle_group column has six values too, but not the same six:
--   chest · back · legs · shoulders · arms · core
--
-- Quads and hamstrings are separate `muscles` rows but both roll up to 'legs',
-- and the design wants them as separate bars — reasonably, since "legs: 22
-- sets" hides the exact imbalance the panel exists to surface (16 quads, 6
-- hamstrings is a real problem that a single leg bar would show as healthy).
--
-- Rather than repurpose muscle_group — which plan generation reads, and which
-- is a correct anatomical grouping — this adds a display axis alongside it.
-- Two different questions, two columns.
-- =============================================================================

alter table muscles
  add column if not exists display_group text;

comment on column muscles.display_group is
  'Bucket for the Progress "sets per muscle" panel. Distinct from muscle_group, '
  'which is the anatomical grouping plan generation uses: display splits legs '
  'into quads/hamstrings because that imbalance is what the panel is for. '
  'NULL means the muscle is not shown as its own bar.';

update muscles set display_group = 'Chest'      where slug in ('chest');
update muscles set display_group = 'Back'       where slug in ('lats', 'traps', 'rhomboids', 'lower-back');
update muscles set display_group = 'Shoulders'  where slug in ('front-delt', 'side-delt', 'rear-delt');
update muscles set display_group = 'Arms'       where slug in ('biceps', 'triceps', 'forearms');
update muscles set display_group = 'Quads'      where slug in ('quads');
update muscles set display_group = 'Hamstrings' where slug in ('hamstrings', 'glutes');
-- Beyond the design's six fixture groups: honest own-groups rather than
-- misattributing. weekly_sets_by_muscle() only returns groups with logged
-- sets, so these appear only when actually trained.
update muscles set display_group = 'Calves'     where slug in ('calves');
update muscles set display_group = 'Adductors'  where slug in ('adductors');
update muscles set display_group = 'Core'       where slug in ('abs', 'obliques');

-- Calves, adductors, abs and obliques deliberately get no bar: six bars is what
-- the design draws, and a seventh for calves would be noise next to the
-- imbalances that matter. Their sets still count toward volume elsewhere.


-- ── weekly sets per display group ───────────────────────────────────────
-- A set counts toward a group when the exercise has a PRIMARY muscle in it.
-- Secondary and stabiliser contributions are excluded: counting bench toward
-- triceps would double-count the same set into two bars and make every bar
-- look healthier than the training is. This matches how the 10-20 set
-- landmark is defined in the literature the design cites.
create or replace function weekly_sets_by_muscle(p_user_id uuid, p_since date)
returns table (display_group text, set_count bigint)
language sql stable security invoker as $$
  select m.display_group, count(distinct ss.id) as set_count
    from session_sets ss
    join session_exercises se on se.id = ss.session_exercise_id
    join workout_sessions  ws on ws.id = se.session_id
    join exercise_muscles  em on em.exercise_id = se.exercise_id and em.role = 'primary'
    join muscles           m  on m.id = em.muscle_id
   where se.user_id = p_user_id
     and ws.status = 'completed'
     and ws.performed_on >= p_since
     and ss.is_completed
     -- Warm-ups are not stimulus. See decision D2 — this predicate is here now
     -- so that turning on a warm-up toggle later needs no backfill.
     and ss.kind = 'working'
     and m.display_group is not null
   group by m.display_group;
$$;

grant execute on function weekly_sets_by_muscle(uuid, date) to authenticated;

comment on function weekly_sets_by_muscle(uuid, date) is
  'Sets per display group since p_since, primary-muscle only so one set lands in '
  'exactly one bar. The panel compares these against a 10-20 band.';
