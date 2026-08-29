# Exercise Control (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Let a lifter replace an exercise until they have touched it, add exercises beyond the generated plan, and create private ones of their own — with an optional photo that quietly fills the catalogue's illustration gap.

**Architecture:** Two migrations first (scope + RLS), because every UI task depends on them. Then the picker gains filters and a scope prompt, then the entry points, then creation.

**Spec:** `docs/superpowers/specs/2026-08-29-session-flow-and-exercise-control-design.md`

## Global Constraints

- Every tappable in `lib/screens/**` uses `Pressable` — never raw `GestureDetector(onTap:)`/`InkWell`. Enforced by `./tool/check_interactivity.sh`.
- Haptics: `PressFx.light` chips/rows · `medium` primary CTA · `strong` destructive · `none` handler buzzes.
- `flutter analyze lib`: no errors, no warnings; exactly 4 pre-existing infos.
- `flutter test` passes.
- SQL: migrations carry **no** `begin;`/`commit;` — `tool/db_test.sh` and `tool/db_apply.sh` own the transaction and refuse files that do not.
- No unqualified `DELETE`/`UPDATE` inside functions — the role the app connects as refuses them (see `v2_0048`). Always add `where true` if there is no other predicate.
- Custom exercises are **private**: `owner_id = auth.uid()`, `is_core = false`. The generator already filters `owner_id is null and is_core`, so it ignores them with no change.
- Do not touch `lib/screens/{today,chat,settings,onboarding}` or `app_shell.dart`.

---

## Task 1: Swaps can expire

A swap must be able to mean "just today" as well as "every week". Rather than a
second mechanism, `exercise_swaps` gains an end date: null = standing.

**Files:** create `supabase/migrations_v2/v2_0052_swap_scope.sql`, create `supabase/tests/v2_0052_swap_scope_test.sql`

- [ ] **Step 1: Write the migration**

```sql
-- =============================================================================
-- v2_0052 — a swap can be for today only
--
-- Replacing an exercise had exactly one meaning: forever. But "the squat rack
-- was busy so I did leg press once" is not a programme change, and forcing it
-- to be one is how a plan drifts away from what the lifter actually chose.
--
-- Rather than a second mechanism, the existing standing swap gains an end
-- date. Null still means standing, so every existing row keeps its meaning.
-- =============================================================================

alter table exercise_swaps
  add column if not exists expires_on date;

comment on column exercise_swaps.expires_on is
  'Last day this substitution applies. Null = standing, which is what every '
  'row created before v2_0052 means.';

-- p_until null keeps the old behaviour, so existing callers are unaffected.
create or replace function swap_exercise(
  p_from_exercise_id uuid,
  p_to_exercise_id uuid,
  p_until date default null
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_tp  training_profiles%rowtype;
  v_kg  numeric;
  v_ok  boolean;
begin
  if v_uid is null then raise exception 'not authorized'; end if;

  select exists (select 1 from swap_candidates(p_from_exercise_id) c
                  where c.exercise_id = p_to_exercise_id) into v_ok;
  if not v_ok then
    raise exception 'exercise % is not a valid swap for %',
      p_to_exercise_id, p_from_exercise_id;
  end if;

  insert into exercise_swaps (user_id, from_exercise_id, to_exercise_id, expires_on)
  values (v_uid, p_from_exercise_id, p_to_exercise_id, p_until)
  on conflict (user_id, from_exercise_id)
    do update set to_exercise_id = excluded.to_exercise_id,
                  expires_on     = excluded.expires_on,
                  created_at     = now();

  select * into v_tp from training_profiles
   where user_id = v_uid and valid_to is null;

  select max(db.top_weight_kg) into v_kg
    from v_exercise_daily_bests db
   where db.user_id = v_uid and db.exercise_id = p_to_exercise_id;

  if v_kg is null then
    select e.default_start_kg into v_kg from exercises e where e.id = p_to_exercise_id;
    if v_tp.has_benched is false and v_kg is not null and v_kg > 0 then
      v_kg := round(v_kg * 0.4, 1);
    end if;
  end if;
  if v_kg is not null then v_kg := snap_to_loadable(v_uid, v_kg); end if;

  update program_day_exercises pde
     set exercise_id = p_to_exercise_id,
         target_weight_kg = v_kg
    from program_days pd
    join programs p on p.id = pd.program_id
   where pde.program_day_id = pd.id
     and p.user_id = v_uid and p.status = 'active'
     and pde.exercise_id = p_from_exercise_id
     and not exists (select 1 from program_day_exercises x
                      where x.program_day_id = pde.program_day_id
                        and x.exercise_id = p_to_exercise_id);
end $$;

revoke all on function swap_exercise(uuid, uuid, date) from public;
grant execute on function swap_exercise(uuid, uuid, date) to authenticated;

-- An expired swap must stop being reapplied when the plan is rebuilt.
create or replace function _v2_0052_patch() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'bootstrap_user_program';
  if position('from exercise_swaps s, program_days pd' in v_src) = 0 then
    raise exception 'v2_0052: bootstrap swap post-pass not found — refusing to patch blind';
  end if;
  execute 'create or replace function public.bootstrap_user_program('
       || 'p_user_id uuid, p_bench_start_kg numeric default null) returns uuid '
       || 'language plpgsql security definer '
       || 'set search_path to ''public'', ''pg_temp'' as $body$'
       || replace(v_src,
            'where s.user_id = p_user_id',
            'where s.user_id = p_user_id'
            || chr(10) || '     and (s.expires_on is null or s.expires_on >= v_start)')
       || '$body$';
end $patch$;
select _v2_0052_patch();
drop function _v2_0052_patch();
```

- [ ] **Step 2: Write the test**

```sql
savepoint scope;
DO $$
declare v_uid uuid; v_bench uuid; v_alt uuid; v_prog uuid;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
  delete from exercise_swaps where user_id = v_uid;
  update training_profiles set experience='intermediate', environment='commercial_gym',
         split_preference='push_pull_legs', has_benched=true,
         training_weekdays=array[1,3,5]::smallint[]
   where user_id=v_uid and valid_to is null;
  v_prog := bootstrap_user_program(v_uid);

  select id into v_bench from exercises where slug='bench-press' and owner_id is null;
  select exercise_id into v_alt from swap_candidates(v_bench) where is_core limit 1;

  -- A standing swap still survives a rebuild.
  perform swap_exercise(v_bench, v_alt, null);
  v_prog := bootstrap_user_program(v_uid);
  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'standing swap did not survive a rebuild';
  end if;
  raise notice 'standing swap  -> survives rebuild';

  -- One expiring yesterday must not be reapplied.
  update exercise_swaps set expires_on = current_date - 1
   where user_id=v_uid and from_exercise_id=v_bench;
  v_prog := bootstrap_user_program(v_uid);
  if not exists (select 1 from program_day_exercises pde
                   join program_days pd on pd.id=pde.program_day_id
                  where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'an expired swap was still applied';
  end if;
  raise notice 'expired swap   -> not reapplied, original lift back';

  -- One expiring today still applies today.
  perform swap_exercise(v_bench, v_alt, current_date);
  v_prog := bootstrap_user_program(v_uid);
  if exists (select 1 from program_day_exercises pde
               join program_days pd on pd.id=pde.program_day_id
              where pd.program_id=v_prog and pde.exercise_id=v_bench) then
    raise exception 'a swap expiring today was dropped too early';
  end if;
  raise notice 'today-only swap -> applies today';
  raise notice 'V2_0052 SWAP SCOPE: PASS';
end $$;
rollback to savepoint scope;
```

- [ ] **Step 3: Run it, then apply**

```bash
./tool/db_test.sh -m supabase/migrations_v2/v2_0052_swap_scope.sql supabase/tests/v2_0052_swap_scope_test.sql
./tool/db_apply.sh supabase/migrations_v2/v2_0052_swap_scope.sql
```

- [ ] **Step 4: Re-run the whole SQL suite and the sweep**

```bash
for t in supabase/tests/*_test.sql; do echo "== $t"; ./tool/db_test.sh "$t" 2>&1 | grep -E 'ERROR|PASS|OK' | head -2; done
./tool/db_test.sh supabase/tests/v2_matrix_sweep.sql 2>&1 | grep -E 'swept|SWEEP'
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations_v2/v2_0052_swap_scope.sql supabase/tests/v2_0052_swap_scope_test.sql
git commit -m "feat(db): a swap can be for today only

Replacing an exercise meant forever. But 'the rack was busy so I did leg
press once' is not a programme change, and forcing it to be one is how a plan
drifts from what the lifter chose. exercise_swaps gains an end date; null
still means standing, so every existing row keeps its meaning."
```

---

## Task 2: A lifter can describe their own exercise

`exercises` already has correct RLS for user-owned rows. The join tables do
not: each carries only a read policy, so a lifter could create an exercise and
then fail to attach its muscle — an orphan the picker cannot filter.

**Files:** create `supabase/migrations_v2/v2_0053_own_exercise_details.sql`, create `supabase/tests/v2_0053_own_exercise_test.sql`

- [ ] **Step 1: Write the migration**

```sql
-- =============================================================================
-- v2_0053 — let a lifter attach details to an exercise they own
--
-- exercises already reads `owner_id is null or owner_id = auth.uid()` and
-- writes own rows. But exercise_muscles and exercise_equipment carry ONLY a
-- read policy, so creating a custom exercise would succeed and then fail to
-- describe it — leaving a row the picker cannot filter by muscle and the
-- equipment filter cannot place.
--
-- Scoped to exercises the caller OWNS, not merely to authenticated. Anything
-- looser would let one lifter attach a muscle to a CATALOGUE exercise and
-- change what every other lifter is prescribed.
-- =============================================================================

drop policy if exists exercise_muscles_write_own on exercise_muscles;
create policy exercise_muscles_write_own on exercise_muscles
  for all
  using (exists (select 1 from exercises e
                  where e.id = exercise_muscles.exercise_id
                    and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from exercises e
                       where e.id = exercise_muscles.exercise_id
                         and e.owner_id = (select auth.uid())));

drop policy if exists exercise_equipment_write_own on exercise_equipment;
create policy exercise_equipment_write_own on exercise_equipment
  for all
  using (exists (select 1 from exercises e
                  where e.id = exercise_equipment.exercise_id
                    and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from exercises e
                       where e.id = exercise_equipment.exercise_id
                         and e.owner_id = (select auth.uid())));
```

- [ ] **Step 2: Write the test — it must prove the scope, not just the grant**

```sql
savepoint own;
DO $$
declare v_uid uuid; v_mine uuid; v_cat uuid; v_muscle uuid; v_blocked boolean := false;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select id into v_muscle from muscles where name='Chest';
  select id into v_cat from exercises where slug='bench-press' and owner_id is null;

  insert into exercises (slug, name, pattern, load_type, owner_id, is_core, min_experience)
  values ('my-test-lift-'||substr(md5(random()::text),1,6), 'My Test Lift',
          'push', 'weight_reps', v_uid, false, 'beginner')
  returning id into v_mine;

  insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
  values (v_mine, v_muscle, 'primary', 1.0);
  raise notice 'own exercise    -> muscle attached';

  begin
    insert into exercise_muscles (exercise_id, muscle_id, role, contribution)
    values (v_cat, v_muscle, 'secondary', 0.5);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'a lifter attached a muscle to a CATALOGUE exercise';
  end if;
  raise notice 'catalogue lift  -> refused, as it must be';
  raise notice 'V2_0053 OWN EXERCISE DETAILS: PASS';
end $$;
rollback to savepoint own;
```

- [ ] **Step 3: Test, apply, re-run the suite, commit**

```bash
./tool/db_test.sh -m supabase/migrations_v2/v2_0053_own_exercise_details.sql supabase/tests/v2_0053_own_exercise_test.sql
./tool/db_apply.sh supabase/migrations_v2/v2_0053_own_exercise_details.sql
git add supabase/migrations_v2/v2_0053_own_exercise_details.sql supabase/tests/v2_0053_own_exercise_test.sql
git commit -m "feat(db): let a lifter describe an exercise they own

exercises already had correct RLS for user-owned rows, but the join tables
were read-only — so creating a custom exercise would succeed and then fail to
attach its muscle, leaving an orphan the picker cannot filter.

Scoped to exercises the caller OWNS, not merely to authenticated: anything
looser would let one lifter attach a muscle to a catalogue exercise and change
what everyone else is prescribed. The test proves the refusal, not just the
grant."
```

---

## Task 3: Filters and a scope prompt in the picker

**Files:** modify `lib/screens/v2/swap_sheet.dart`, modify `lib/services/supabase_service_v2.dart`

- [ ] **Step 1: Widen the service call**

In `lib/services/supabase_service_v2.dart`, change `swapExercise` to carry scope:

```dart
  /// [until] null = standing (survives regeneration); a date = expires after it.
  Future<void> swapExercise(String fromId, String toId, {DateTime? until}) =>
      client.rpc('swap_exercise', params: {
        'p_from_exercise_id': fromId,
        'p_to_exercise_id': toId,
        'p_until': until == null
            ? null
            : '${until.year.toString().padLeft(4, '0')}-'
              '${until.month.toString().padLeft(2, '0')}-'
              '${until.day.toString().padLeft(2, '0')}',
      });
```

- [ ] **Step 2: Add filter chips above the list**

In `swap_sheet.dart`, add state `String? _pattern;` and `String? _muscle;`. Between
the search field and the list, render two scrollable chip rows built with
`Pressable` (`PressFx.light`): patterns `Push / Pull / Legs / Core` (mapped to
the candidate's own pattern — derive it from the candidate list rather than
hardcoding), and the distinct `muscle` values present in the loaded candidates.
Tapping a selected chip clears it. Apply both to `_filtered` alongside the
existing search.

`SwapCandidateV2` already carries `muscle`; add `pattern` to it and to
`swap_candidates`' return if not present — check first, and if `pattern` is not
returned, group the muscle chips only and skip the pattern row rather than
inventing a column.

- [ ] **Step 3: Ask the scope on selection**

Replace the immediate `_apply(c)` with a small confirm sheet offering
**Just today** and **Every week**, plus Cancel. "Just today" passes
`until: DateTime.now()`; "Every week" passes `until: null`. Copy for the sheet
body: `Swapping <old> for <new>.`

- [ ] **Step 4: Verify and commit**

```bash
flutter analyze lib && flutter test && ./tool/check_interactivity.sh
git add lib/screens/v2/swap_sheet.dart lib/services/supabase_service_v2.dart
git commit -m "feat(train): filter the swap picker, and ask how long a swap lasts"
```

---

## Task 4: Replace from anywhere it is still honest

**Files:** modify `lib/screens/v2/train_screen.dart`, modify `lib/screens/v2/session_flow_screen.dart`, modify `lib/services/session_controller.dart`

- [ ] **Step 1: A visible affordance on the Train tab**

`_PlanRow` already opens the sheet on tap. Add a `swap_horiz_rounded` icon at
the row's trailing edge (16px, `AppColors.textFaint`) so it reads as
replaceable rather than merely tappable. Do not add a second gesture.

- [ ] **Step 2: Replace in-session while a lift is untouched**

Add to `SessionController`:

```dart
  /// A lift can be replaced until it has been touched — a logged set, not the
  /// start of the session. Swapping one with sets against it would orphan them.
  bool canReplace(int i) => _sets[i].isEmpty;

  /// Swap the lift at [i] for [toId], then reload the plan so the new lift's
  /// prescription and prefill are the server's, not a guess made here.
  Future<void> replaceLift(int i, String toId, {DateTime? until}) async {
    await _svc.swapExercise(exercises[i].exerciseId, toId, until: until);
    final fresh = await _svc.fetchTrainScreen();
    final next = fresh?.exercises;
    if (next == null || next.length != exercises.length) return;
    exercises = next;
    _planned[i] = null;   // re-seed against the new lift's prefill
    notifyListeners();
  }
```

`exercises` must be non-final for this. If it is `final`, make it mutable and
say why in a comment.

- [ ] **Step 3: Offer it from the in-session board**

In `_BoardSheet`/`_BoardRow`, add a Replace action on rows where
`c.canReplace(i)` is true, opening the same swap sheet and calling
`c.replaceLift`. Rows with logged sets show no such action.

- [ ] **Step 4: Verify and commit**

```bash
flutter analyze lib && flutter test && ./tool/check_interactivity.sh
git add -A && git commit -m "feat(train): replace a lift until you have touched it"
```

---

## Task 5: Add an exercise to a day

**Files:** modify `lib/screens/v2/train_screen.dart`, modify `lib/services/supabase_service_v2.dart`, create `supabase/migrations_v2/v2_0054_add_day_exercise.sql`

- [ ] **Step 1: The RPC**

```sql
-- =============================================================================
-- v2_0054 — add an exercise to a day
--
-- The generator caps a session at 4-6 lifts, which is a rule about what WE
-- prescribe, not a limit on what a lifter may do. Appending is theirs.
-- =============================================================================

create or replace function add_day_exercise(p_program_day_id uuid, p_exercise_id uuid)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ord int;
  v_kg  numeric;
  v_rx  record;
begin
  if v_uid is null then raise exception 'not authorized'; end if;
  if not exists (select 1 from program_days pd join programs p on p.id = pd.program_id
                  where pd.id = p_program_day_id and p.user_id = v_uid) then
    raise exception 'not your program day';
  end if;
  if exists (select 1 from program_day_exercises
              where program_day_id = p_program_day_id and exercise_id = p_exercise_id) then
    return;  -- already there; adding twice is a no-op, not an error
  end if;

  select coalesce(max(ordinal), 0) + 1 into v_ord
    from program_day_exercises where program_day_id = p_program_day_id;

  select * into v_rx from plan_goal_prescription(
    coalesce((select goals[1] from training_profiles
               where user_id = v_uid and valid_to is null), 'build_muscle'));

  select coalesce(
    (select max(db.top_weight_kg) from v_exercise_daily_bests db
      where db.user_id = v_uid and db.exercise_id = p_exercise_id),
    (select e.default_start_kg from exercises e where e.id = p_exercise_id))
    into v_kg;
  if v_kg is not null then v_kg := snap_to_loadable(v_uid, v_kg); end if;

  insert into program_day_exercises
    (program_day_id, exercise_id, ordinal, sets_target, rep_low, rep_high,
     target_weight_kg, rest_seconds)
  values (p_program_day_id, p_exercise_id, v_ord, 3,
          v_rx.rep_low, v_rx.rep_high, v_kg, v_rx.rest_isolation);
end $$;

revoke all on function add_day_exercise(uuid, uuid) from public;
grant execute on function add_day_exercise(uuid, uuid) to authenticated;
```

- [ ] **Step 2: A browse RPC that is not tied to one exercise**

`swap_candidates` needs a source exercise. Adding needs the whole reachable
catalogue. Add to the same migration:

```sql
create or replace function browse_exercises(p_query text default null)
returns table (
  exercise_id uuid, slug text, name text, is_core boolean,
  mechanic text, equipment text, muscle text, pattern text,
  min_experience experience_level, demo_path text, is_mine boolean
)
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  with me as (select (select auth.uid()) as uid),
  tp as (select coalesce(t.environment,'commercial_gym') env,
                coalesce(t.experience,'intermediate') exp
           from training_profiles t, me
          where t.user_id = me.uid and t.valid_to is null)
  select distinct on (e.id)
         e.id, e.slug, e.name, e.is_core, e.mechanic,
         (select q.name from exercise_equipment ee join equipment q on q.id = ee.equipment_id
           where ee.exercise_id = e.id order by ee.is_required desc, q.name limit 1),
         (select m.name from exercise_muscles em join muscles m on m.id = em.muscle_id
           where em.exercise_id = e.id and em.role='primary' order by m.name limit 1),
         e.pattern::text, e.min_experience, e.demo_path,
         e.owner_id is not null
    from exercises e, tp, me
   where (e.owner_id is null or e.owner_id = me.uid)
     and e.load_type in ('weight_reps','bodyweight_reps')
     and (p_query is null or e.name ilike '%'||p_query||'%')
     and (e.owner_id is not null or e.min_experience <= tp.exp)
     and (e.owner_id is not null or not exists (
           select 1 from exercise_equipment ee
            where ee.exercise_id = e.id and ee.is_required
              and not exists (select 1 from environment_equipment env
                               where env.equipment_id = ee.equipment_id
                                 and env.environment = tp.env)))
   order by e.id;
$$;

grant execute on function browse_exercises(text) to authenticated;
```

A lifter's own exercises bypass the environment and training-age filters: they
described it and chose it, so filtering it out of their own list would be the
app overruling them about their own gym.

- [ ] **Step 3: UI** — "+ Add exercise" at the end of `_PlanList`, opening a picker
built on `browse_exercises` with the same search and chips as Task 3, calling
`add_day_exercise`, then `_load()`.

- [ ] **Step 4: Test, apply, verify, commit** — same shape as Task 1 Step 3-5.

---

## Task 6: Create your own exercise

**Files:** create `lib/screens/v2/create_exercise_sheet.dart`, modify the picker from Task 5, modify `lib/services/supabase_service_v2.dart`

- [ ] **Step 1: Service method**

```dart
  /// A private exercise. owner_id set + is_core false means the generator
  /// ignores it — it already filters `owner_id is null and is_core`.
  Future<String?> createExercise({
    required String name,
    required String pattern,      // push | pull | legs | core
    String? muscleId,             // optional
    String? equipmentId,          // optional
    bool bodyweight = false,
  }) async {
    final uid = currentUser?.id;
    if (uid == null) return null;
    final slug = '${name.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "-")}'
        '-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final row = await client.from('exercises').insert({
      'slug': slug,
      'name': name.trim(),
      'pattern': pattern,
      'load_type': bodyweight ? 'bodyweight_reps' : 'weight_reps',
      'owner_id': uid,
      'is_core': false,
      'min_experience': 'beginner',
      'source': 'user',
    }).select('id').single();
    final id = row['id'] as String;
    if (muscleId != null) {
      await client.from('exercise_muscles').insert(
          {'exercise_id': id, 'muscle_id': muscleId, 'role': 'primary', 'contribution': 1.0});
    }
    if (equipmentId != null) {
      await client.from('exercise_equipment').insert(
          {'exercise_id': id, 'equipment_id': equipmentId, 'is_required': true});
    }
    return id;
  }
```

- [ ] **Step 2: The sheet** — name (required), pattern (4 chips, required),
muscle (optional dropdown from `muscles`), equipment (optional, from `equipment`),
a bodyweight toggle, and an optional photo. Reached from "Can't find it? Create
one" at the bottom of the picker.

- [ ] **Step 3: Photo upload** — reuse the `exercise-media` bucket under
`user/<uid>/<slug>.jpg`, then set `demo_path`. Optional throughout: a lifter
who skips it gets the placeholder, exactly as catalogue lifts without an
illustration do.

- [ ] **Step 4: Verify and commit.**

---

## Task 7: Add a photo to a lift that has none

**Files:** modify `lib/screens/v2/session_flow_screen.dart` (`_GuideMedia`)

- [ ] **Step 1:** When `demoUrl` is null, replace the bare dumbbell icon with a
`Pressable` "Add a photo" affordance. On tap, pick an image, upload it, and set
`demo_path` — but only for an exercise the lifter OWNS. For a catalogue
exercise with no illustration, keep the placeholder and no action: they cannot
write to a catalogue row, and offering an action that will fail is worse than
offering none.

- [ ] **Step 2: Verify and commit.**
