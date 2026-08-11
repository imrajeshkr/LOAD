# LOAD — handoff

> **Status as of the `today-screen-results` branch.** Re-read this before
> assuming anything; the section below is the only part kept current.

## Right now

| | |
|---|---|
| **Branch** | `today-screen-results` — **PR #2 open**, contains migrations 0011–0015 |
| **PR #1** | merged into `main` (v2 schema + Gemini coach) |
| **Database** | `saiwblhqfyxpwkgnhptd` — migrations **0003–0015 all applied and live** |
| **Edge Function** | `coach` deployed, `GEMINI_API_KEY` set |
| **Uncommitted** | `lib/models/models.dart` only |

### The one thing in flight

`lib/models/models.dart` has the client shapes for the new backend —
`ExerciseEffort`, `SetProgress`, and `last`/`today`/`loadType`/`prefillKg` on
`ExerciseSpec`. **Nothing consumes them yet.** This is not a staging decision:
a background agent was wiring the whole client side and was stopped after
editing this one file. `flutter analyze` is clean because every new field is
optional or defaulted.

Verified by grep: `today_plan`, `ExerciseEffort` and `SetProgress` appear
nowhere in `supabase_service.dart`, `app_state.dart` or `lib/screens/today/`.
The client still calls the older plan loader that reads
`program_day_exercises` directly, so **none of the Today-screen fix is visible
in the app yet** — a bodyweight exercise still renders `0 kg · Done`.

### Next step, and the collision risk

The natural next task is wiring the client: `fetchTodayPlan()` calling the
`today_plan` RPC, then `AppState` deriving logged state from it instead of the
local `loggedSets` map keyed by plan position, then the Today and Log screens.

**Only one session should do this.** It touches `supabase_service.dart`,
`app_state.dart`, `today_screen.dart`, `log_screen.dart`, `progress_screen.dart`
and `models.dart` together; two agents editing them concurrently will clobber
each other.

### Backend available to wire against

| Call | Returns |
|---|---|
| `today_plan(uuid) -> jsonb` | prescription, last session's real sets, today's logged sets, prefill, `session_now`, `session_last` |
| `open_session_for_today(uuid, text) -> uuid` | the session for the lifter's **local** day, creating it if needed |
| `protein_target_for(uuid)` | `(grams, basis_kg, per_kg, rationale)` — goal-derived |
| `sync_protein_target(uuid) -> int` | persists it to `nutrition_targets` |
| `last_same_day_totals(uuid, text, date)` | the same program day, last time — matched by **label**, not id |
| `v_bodyweight_trend` | `raw_kg` plus `avg_7d` 7-day trailing mean |
| `user_today(uuid) -> date` | the lifter's local date |

### Still not built (UX, no backend blocker)

Rest timer from the prescribed `rest_seconds`; weight/reps persisting between
sets; editing any set rather than only undoing the last; a session header with
elapsed time and position; a prompt when the set target is met; and the
session-level result line using `session_now` / `session_last`.

---

## Reference — invariants, bugs, and the original test list

### Two invariants — do not break these

**The Edge Function must never use `service_role`.** It builds its Supabase
client from the caller's JWT (`supabase/functions/coach/index.ts`), so every
read is already constrained by RLS. A prompt-injected model can ask for
anything and still only see one lifter's data. Switching to `service_role`
turns every injection bug into a cross-tenant leak.

**The model must never write training data.** `propose_set_log` only inserts a
`pending` row in `coach_proposals`. `/coach/confirm` executes it, guarded by
`where status = 'pending'` so a double tap cannot double-log. Keep new
state-changing tools on the proposal path.

---

## 3. Verified working

- **Today** — program from the DB, per-exercise injury warnings, weigh-in,
  protein target/streak.
- **Progress** — consistency heatmap, bodyweight trend, session history.
- **Coach guidance** — asked "why has my bench stalled?", got a reply citing
  80 kg on Aug 5, 82.2 kg bodyweight, 127 g protein. Every number traceable to
  a real row.
- **Coach logging** — natural language → resolved exercise → confirm card →
  sets written. 4 proposals confirmed, 5 distinct exercises logged.
- **Injury filter** — Overhead Press (severe shoulder stress) is excluded from
  the generated program for a lifter with a flagged shoulder; Landmine Press
  covers front delts instead. Bench Press is programmed *with* a warning.

---

## 4. Bugs already found and fixed

Listed because each one is a trap that can reappear.

1. **PGRST201 ambiguous embed.** `session_exercises` has *two* FKs to
   `exercises` (`exercise_id`, `swapped_from_exercise_id`), so a bare
   `exercises(...)` embed is rejected. Always qualify:
   `exercises!session_exercises_exercise_id_fkey(...)`. Same applies to
   `exercise_alternatives`. This is the bug that made Confirm look broken.
2. **Unguarded refresh stranding the UI.** `confirmPendingLog` cleared the card,
   then called `refreshProgress()` unguarded. When it threw, `notifyListeners()`
   never ran and the card stayed on screen for work that *had* been saved. Any
   post-write refresh must be guarded.
3. **Alphabetical program generation.** First cut used `order by name limit 4`,
   producing a Push Day of three chest presses and a fly. Now picks one movement
   per primary muscle, compound-first (`0008`).
4. **0 kg working weights** for movements with no history — the old hardcoded
   starting weights had been dropped. Now `exercises.default_start_kg` (`0009`).
5. **Orphaned accounts.** Dropping `profiles` left pre-existing `auth.users` with
   no profile/preferences, because `handle_new_user` only fires on INSERT (`0007`).
6. **Fuzzy match outranking exact aliases.** `word_similarity('bench', 'DB Bench
   Press')` = 1.0 beat "Bench Press"'s 0.97 alias hit. Fuzzy scores are now
   capped at 0.85, below all deterministic tiers.
7. **`<%` operator threshold.** Uses `pg_trgm.word_similarity_threshold`
   (default 0.6), silently missing ordinary typos. Call `word_similarity()`
   directly instead.
8. **Caution vs contraindicated.** A *moderate* joint flag was marking nearly
   every press as forbidden, contradicting the app's own UI. Now two distinct
   outcomes; only severe combinations are hard exclusions (`0006`).
9. **Bare shorthand not logging.** `hammer curls 14x12x3` (no verb) was answered
   as a question, even though the app's input hint teaches exactly that format.
   Fixed in the system prompt in `context.ts`.

---

## 5. What to test next

Nothing below has been exercised.

- [ ] **Onboarding end to end.** Sign in as `kr.rajesh117@gmail.com`, complete
      onboarding, confirm `bootstrap_my_program` produces a sensible program.
      This is the highest-value untested path.
- [ ] **The in-app logging flow** (Today → Start session → log sets → Summary).
      Only the *chat* logging path has been verified.
- [ ] **Exercise swap** from the injury banner (`swapExercise`/`canSwap` now read
      `exercise_alternatives` from the DB).
- [ ] **Unit switching** to imperial — all conversion happens at the UI edge and
      in the coach's context pack; both need checking.
- [ ] **The `remember` tool** — `coach_memories` has never been written to.
- [ ] **Offline fallback.** Kill the Edge Function (or go offline) and confirm
      chat still logs via the local regex parser.
- [x] ~~**Double-confirm idempotency.**~~ Verified against production: replaying
      a confirm changes 0 rows.
- [x] ~~**Profile round-trip.**~~ Verified: goal / experience / days / environment
      all load back correctly through the enum↔display-label mapping.
- [ ] **Deload / rest-day rendering** when `scheduled_workouts` has nothing for
      today. Not testable while a workout is scheduled — shift the slot forward
      a day in SQL, check, then restore.

---

## 6. What to build next

Roughly in value order.

1. **Golden set for the log parser.** ~100 real utterances → expected proposal
   JSON, run on every deploy. This is the part that silently breaks and where
   regressions corrupt data.
2. **Streaming replies.** Currently the Edge Function returns one JSON blob, so
   the coach feels slow on longer answers. `streamGenerateContent?alt=sse`.
3. **`propose_swap` and `propose_program_change`.** Declared in the design, not
   implemented — the coach can log but cannot yet change the plan.
4. **Progression applied to the program.** `coach_next_load` exists and is
   correct, but nothing writes its suggestion back into
   `program_day_exercises.target_weight_kg`.
5. **Explicit context caching.** Currently relying on implicit prefix caching.
   Gemini `cachedContents` needs ≥4096 tokens and TTL management.
6. **`program_blocks`** (mesocycles/deloads) — table exists, nothing uses it.
7. **Rolling thread summary.** `loadHistory` keeps the last 12 turns and drops
   the rest; long threads lose context entirely.
8. **Settings UI for `coach_memories`** so users can see and delete what the
   coach remembers.

---

## 7. Practical notes

```bash
# run SQL against production
supabase db query --linked "select ..."
supabase db query --linked -f path/to.sql        # -f for files; a leading `--` comment breaks the inline form

# deploy the coach
supabase functions deploy coach

# verify the schema locally before touching production
docker run -d --name load-pg -e POSTGRES_PASSWORD=pg postgres:17-alpine
# then apply 0003→0009 against it (needs an auth.users + auth.uid() stub)
```

- Migrations are named `0001_`-style, **not** Supabase's timestamp convention.
  The remote had v1 applied with no migration history, so `0001`/`0002` were
  marked applied via `supabase migration repair --status applied 0001 0002`.
  Do not re-run those two.
- The provider seam is `supabase/functions/coach/gemini.ts` — the only file that
  knows the vendor. Gemini specifics that bite: no `system` role inside
  `contents`; tool results go back as a **user** turn with `functionResponse`
  parts; `thoughtSignature` parts must be echoed back verbatim (so replay the
  whole `parts` array); a blocked prompt returns **HTTP 200 with no candidates**.
- A Vercel plugin hook fires on `supabase/**` edits suggesting storage docs.
  It is a path-pattern false positive — this project has no Vercel involvement.
