# LOAD — handoff

Context for continuing work. Everything below is deployed and verified live
unless marked otherwise.

---

## 1. Where things stand

**Supabase project:** `saiwblhqfyxpwkgnhptd` (name: "Load"). CLI is linked.
Note it is **not** in the same Supabase account as most other projects — a
`supabase login` with the owning account is required before any CLI work.

| Piece | State |
|---|---|
| v2 schema (migrations `0003`–`0009`) | applied to production |
| Exercise catalog (36 movements) | seeded |
| Edge Function `coach` (Gemini) | deployed, `GEMINI_API_KEY` set as a secret |
| Flutter client | rewritten for v2, builds, verified on simulator |
| `rajesh.test4@example.com` | seeded — 27 sessions, 351 sets, active program |
| `kr.rajesh117@gmail.com` | provisioned but no training profile → lands on onboarding |
| Git | **nothing committed.** ~45 files changed |
| `v1_backup_*` tables | still on the server; drop when confident |

### Architecture in one paragraph

Four layers: **catalog** (global exercises, muscles, joints, cues, swaps),
**prescription** (`programs → program_days → program_day_exercises →
scheduled_workouts`), **performance** (`workout_sessions → session_exercises →
session_sets`), and **signal** (body measurements, nutrition, coach threads).
The coach is a Supabase Edge Function that assembles a context pack from SQL
views, calls Gemini with tools, and can only ever create a *pending proposal* —
turning that into rows happens in a separate endpoint with no model in it.

Design docs: `supabase/design/v2_schema_proposal.sql`, `supabase/README.md`.

---

## 2. Two invariants — do not break these

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
- [ ] **Double-confirm idempotency.** Server-guarded but never actually
      double-tapped.
- [ ] **Deload / rest-day rendering** when `scheduled_workouts` has nothing for
      today.

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
