-- =============================================================================
-- LOAD — coach memory, exercise name resolution, and program bootstrap
--
-- Three things the v2 schema implies but doesn't itself provide:
--   1. durable coach memories (facts the database cannot derive)
--   2. deterministic name → exercise_id resolution, so the model never
--      invents a UUID and never silently picks the wrong movement
--   3. a program generator, so a new user has something real on Today
-- =============================================================================

create extension if not exists pg_trgm;

-- ── 1. coach memories ───────────────────────────────────────────────────
-- Only for things a query cannot answer: "hates barbell back squats",
-- "trains at 6am", "calls it OHP". Never derived state like a current 1RM.
create table if not exists coach_memories (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles(id) on delete cascade,
  fact         text not null,
  kind         text not null default 'preference'
                 check (kind in ('preference', 'constraint', 'context', 'vocabulary')),
  -- Which message created it, so a bad memory can be traced back.
  source_message_id uuid,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

create index if not exists coach_memories_user_idx on coach_memories (user_id, created_at desc);

alter table coach_memories enable row level security;
drop policy if exists coach_memories_own on coach_memories;
create policy coach_memories_own on coach_memories for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));


-- ── 2. exercise naming ──────────────────────────────────────────────────
-- Aliases carry the vernacular: "bench", "ohp", "rdl". The trigram index
-- backs fuzzy matching for everything the alias list doesn't cover.
alter table exercises
  add column if not exists aliases text[] not null default '{}',
  -- Which day of a split this movement belongs to. Explicit rather than
  -- derived from muscle group, because "Pullover" and "Face Pull" defy the
  -- obvious derivation and a coach needs to be right about that.
  add column if not exists pattern text
    check (pattern in ('push', 'pull', 'legs', 'core', 'conditioning'));

create index if not exists exercises_name_trgm on exercises using gin (name gin_trgm_ops);
create index if not exists exercises_aliases_idx on exercises using gin (aliases);
create index if not exists exercises_pattern_idx on exercises (pattern) where owner_id is null;

-- Resolve a free-text exercise name for one user. Returns ranked candidates;
-- the caller decides whether the top score is decisive enough to auto-apply.
-- Match order: exact name → exact alias → prefix → fuzzy.
--
-- Fuzzy uses word_similarity rather than similarity: plain trigram similarity
-- scores a short term against a long name badly ("sqaut" vs "Back Squat" is
-- 0.13, under any usable threshold), because it is diluted by the words the
-- user didn't type. word_similarity scores the best-matching word instead.
-- Two details that are easy to get wrong and were caught in testing:
--
--   * The fuzzy score is capped below the deterministic tiers. Uncapped,
--     word_similarity('bench', 'DB Bench Press') scores a perfect 1.0 — it
--     contains the word "bench" — and outranks "Bench Press", which only
--     earns 0.97 from its alias. Fuzzy must never beat an exact alias.
--
--   * word_similarity is called directly rather than via the `<%` operator.
--     `<%` tests against pg_trgm.word_similarity_threshold, which defaults to
--     0.6 and silently rejects ordinary typos ("sqaut" scores 0.33). The
--     catalog is small enough that the lost index usage costs nothing.
create or replace function resolve_exercise(p_user_id uuid, p_name text)
returns table (exercise_id uuid, name text, score real)
language sql stable as $$
  with q as (select lower(trim(p_name)) as term)
  select e.id, e.name,
         (case
            when lower(e.name) = q.term                                  then 1.00
            when q.term = any (select lower(a) from unnest(e.aliases) a) then 0.97
            when lower(e.name) like q.term || '%'                        then 0.90
            else least(0.85, greatest(word_similarity(q.term, lower(e.name)),
                                      similarity(lower(e.name), q.term)))
          end)::real as score
    from exercises e, q
   where (e.owner_id is null or e.owner_id = p_user_id)
     and (lower(e.name) = q.term
          or q.term = any (select lower(a) from unnest(e.aliases) a)
          or lower(e.name) like q.term || '%'
          or word_similarity(q.term, lower(e.name)) > 0.35
          or similarity(lower(e.name), q.term) > 0.3)
   -- Shorter names win ties: "Bench Press" over "DB Bench Press".
   order by score desc, length(e.name) asc
   limit 5;
$$;


-- ── 3. program bootstrap ────────────────────────────────────────────────
-- Builds a real program from the catalog for a user's current training
-- profile, replacing the hardcoded `defaultExercises` constant in the app.
-- Idempotent: archives any existing active program first.
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

  -- One active program per user is enforced by a partial unique index.
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
          v_tp.goal,
          v_tp.split_preference,
          v_tp.days_per_week,
          'active',
          'template',
          v_start)
  returning id into v_program;

  for v_i in 1 .. array_length(v_patterns, 1) loop
    insert into program_days (program_id, ordinal, label)
    values (v_program, v_i, v_labels[v_i])
    returning id into v_day;

    v_ordinal := 0;
    -- Pick catalog movements for this pattern that (a) the user's environment
    -- can equip and (b) don't stress a joint they've flagged. The injury
    -- filter is a WHERE clause, not a prompt instruction.
    for v_ex in
      select e.id, e.default_rep_low, e.default_rep_high
        from exercises e
       where e.owner_id is null
         and e.pattern = v_patterns[v_i]
         and not exists (
               select 1
                 from exercise_equipment ee
                where ee.exercise_id = e.id
                  and ee.is_required
                  and not exists (
                        select 1 from environment_equipment env
                         where env.equipment_id = ee.equipment_id
                           and env.environment  = v_tp.environment))
         and not exists (
               select 1
                 from exercise_joints ej
                 join user_constraints uc
                   on uc.joint_id = ej.joint_id
                  and uc.user_id  = p_user_id
                  and uc.active_to is null
                where ej.exercise_id = e.id
                  and ej.stress_level = 'severe')
       order by e.name
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

  -- Lay the rotation onto the calendar for the next two weeks, skipping
  -- one rest day between sessions.
  insert into scheduled_workouts (user_id, program_id, program_day_id, scheduled_for)
  select p_user_id, v_program, d.id,
         v_start + ((d.ordinal - 1) + (w * array_length(v_patterns, 1))) * 2
    from program_days d
    cross join generate_series(0, 1) as w
   where d.program_id = v_program
  on conflict do nothing;

  return v_program;
end $$;

revoke all on function bootstrap_user_program(uuid) from public;
grant execute on function bootstrap_user_program(uuid) to authenticated;

-- Callers may only bootstrap themselves.
create or replace function bootstrap_my_program()
returns uuid
language plpgsql
security invoker as $$
begin
  return bootstrap_user_program(auth.uid());
end $$;

grant execute on function bootstrap_my_program() to authenticated;
