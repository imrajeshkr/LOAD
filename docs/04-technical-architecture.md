# LOAD — Technical Architecture Document

**Status:** Draft v1 — second of five planning documents, written after the
PRD/Frontend Spec/Feature Ticket List. Describes the system as it actually
exists on `main` (verified against the real migrations, Edge Function
source, and client code while writing this, not recalled from memory), plus
the reasoning behind the decisions that shaped it. The Security & Access
document builds on this one.

---

## 1. System overview

```
┌─────────────────────┐        ┌───────────────────────────────────────┐
│  Flutter client      │        │  Supabase project                     │
│  (iOS + Android,     │  HTTPS │  ┌─────────────┐  ┌──────────────────┐│
│  one codebase)        ├───────┤  │ Postgres     │  │ Edge Function     ││
│                       │        │  │ + Auth       │  │ "coach" (Deno)    ││
│  AppState             │        │  │ + Storage    │  │                   ││
│  (ChangeNotifier,     │        │  │ + RLS        │──┤ builds its own    ││
│  single source of     │        │  └─────────────┘  │ client from the   ││
│  truth for UI)         │        │                    │ caller's JWT      ││
│                       │        │                    └────────┬─────────┘│
│  SupabaseService       │        │                             │          │
│  (only DB access layer)│        │                             │ HTTPS    │
└──────────┬────────────┘        └─────────────────────────────┼──────────┘
           │ anon/publishable key + user JWT, always                       │
           │                                                    ┌──────────▼─────────┐
           └────────────────────────────────────────────────────┤ Gemini (Google AI) │
                                                                  └────────────────────┘
```

Three services, one project: Postgres (with RLS as the actual authorization
layer, not an app-layer check), Auth, and Storage, all under one Supabase
project — plus one Edge Function that mediates every AI interaction. The
Flutter client never talks to Gemini directly and never holds a
service-role credential; both of those are load-bearing constraints, not
incidental choices (Security & Access doc, §"AI write safety").

## 2. Client architecture

**Flutter**, single codebase for iOS + Android, no web target (PRD §9).

- **State**: one `AppState extends ChangeNotifier`, provided at the app
  root via `provider`. Screens `watch`/`read` it; there is no per-screen
  local duplication of server-derived state (the bug this fixed: a local
  `loggedSets` map disagreeing with the server was the root cause of two
  early defects — see `HANDOFF.md` §4 — its removal is a standing
  architectural rule, not just a historical fix).
- **Data access**: one `SupabaseService`, the only file that imports
  `supabase_flutter` directly. Every RPC call, table read, and Storage URL
  resolution goes through it. `AppState` never talks to Supabase directly.
- **Models**: `lib/models/models.dart` — plain Dart classes with
  `fromJson` factories matching each RPC's exact JSON shape 1:1.
  `ExerciseSpec`, `TodayPlan`, `NextSessionPreview`, `SessionTotals` etc.
  are structurally typed to their source RPC, not a generic "API response"
  wrapper.
- **Navigation**: `MaterialApp` + `Navigator` push/pop, no named-route
  table, no external router package. Two registers — persistent tab bar
  (`IndexedStack`) vs. full-screen takeover routes — per Frontend Spec §3.
- **Units**: canonical storage is always kilograms; `UnitSystem`
  (metric/imperial) converts only at the display/input boundary. No screen,
  model, or RPC ever carries a "which unit is this" flag — kg is the only
  value that exists past the UI edge.

## 3. Data architecture

Postgres schema in four layers (the mental model that keeps the RPC surface
legible as it's grown from `today_plan` alone to a dozen functions):

| Layer | Tables | Purpose |
|---|---|---|
| **Catalog** | `exercises`, `muscles`, `joints`, `equipment`, `exercise_muscles`, `exercise_joints`, `exercise_equipment`, `exercise_cues`, `exercise_alternatives` | Global, read-only-to-users reference data. 36 seeded movements with load type, default starting weight, form cues, joint stress, equipment requirements, substitutes. |
| **Prescription** | `programs`, `program_blocks`, `program_days`, `program_day_exercises`, `scheduled_workouts` | What the user is *supposed* to do — a generated program, its days, and the calendar slots those days occupy. |
| **Performance** | `workout_sessions`, `session_exercises`, `session_sets`, `session_pain_reports` | What the user *actually did* — one session per local calendar day (enforced by `open_session_for_today`'s lookup-or-create pattern, not a unique constraint), sets hung off `session_exercises` rather than the exercise directly so a mid-session swap has somewhere to record `swapped_from_exercise_id`. |
| **Signal** | `body_measurements`, `nutrition_entries`, `nutrition_targets`, `coach_threads`, `coach_messages`, `coach_proposals`, `coach_memories` | Everything else the coach reasons from or writes: weigh-ins, protein, chat history, and the proposal queue (Security doc). |

### 3.1 Key RPCs

Every RPC below is `security invoker` (runs as the calling user, RLS
applies to every query inside it) unless noted otherwise — see Security &
Access doc for why that default matters and the one place it's currently
broken.

| RPC | Returns | Purpose |
|---|---|---|
| `today_plan(uuid)` | jsonb | The Today screen's single source of truth: prescription, last session's real sets per exercise, today's logged sets, prefill weight/reps, session totals now/last, demo media path. Rebuilt five times (migrations 0011→0017) as the client's actual needs became clear — see §5 for why that's a normal, not alarming, pattern here. |
| `next_session_preview(uuid)` | jsonb | Mirrors `today_plan`'s exercise-building query, pointed at the next scheduled day instead of today's — backs the "Up next" card. |
| `open_session_for_today(uuid, text)` | uuid | Returns the existing session for the lifter's local day if one exists, else creates it. Both the Today-screen path and chat logging call this, so a day is never split across two session rows. |
| `bootstrap_user_program(uuid)` / `bootstrap_my_program()` | uuid | Generates a program from the catalog for the user's current training profile — one movement per primary muscle pattern, compound-first, environment- and injury-filtered. `bootstrap_user_program` is `security definer`; see Security & Access doc for the access-control gap this currently has. |
| `protein_target_for(uuid)` / `sync_protein_target(uuid)` | table / int | Goal-derived daily protein target (grams per kg bodyweight); sync persists it to `nutrition_targets`. |
| `last_same_day_totals(uuid, label, date)` | jsonb | "Last time you trained Push Day" — matched by the program day's **label**, not its id, because a re-plan mints fresh `program_days` rows and an id-based match silently lost the comparison (`HANDOFF.md` bug #12). |
| `user_today(uuid)` | date | The lifter's local calendar date, derived from their stored timezone — every streak/heatmap/daily aggregate groups on this, never on a raw UTC timestamp. |
| `resolve_exercise(uuid, text)` | table | Fuzzy-matches a chat utterance's exercise name against the catalog (alias table first, then trigram similarity capped below the alias tier so a fuzzy hit can never outrank an exact alias). |
| `coach_catalog` / `coach_weekly_volume` / `coach_exercise_history` / `coach_next_load` | jsonb / table | Read-only context assemblers the Edge Function calls to build what the model sees — profile, recent volume, per-exercise history, and a computed progression suggestion. |

### 3.2 Migration convention

`0001`-style sequential integers, not Supabase's default timestamp
convention (the remote had v1 applied with no migration history when this
started, so `0001`/`0002` were marked applied via `supabase migration
repair` rather than re-run — a one-time bootstrapping fact, not an ongoing
process). 18 migrations as of this document; several (`0011`→`0017`) are
narrow, single-purpose re-declarations of `today_plan()` rather than one
big function — Postgres has no way to `ALTER` a single field out of a
`plpgsql` function body, so adding one JSON field means re-declaring the
whole function, and the migration history reflects that honestly rather
than being squashed.

## 4. AI / coach architecture

One Edge Function (`supabase/functions/coach/`, Deno), three routes:

- `POST /coach` — a chat turn. May return a pending proposal.
- `POST /coach/confirm` — executes a proposal. **No model call on this
  path** — it's a deterministic function of the already-persisted
  proposal payload.
- `POST /coach/reject` — discards a proposal.

Structure:

- `index.ts` — routing, auth (validates the caller's JWT via
  `db.auth.getUser()`, never trusts a client-supplied user id), the
  confirm/reject state machine.
- `context.ts` — assembles what the model sees, split into a **stable
  prefix** (profile, catalog facts — same across turns) and **live
  context** (today's plan, recent history) appended per-turn. The split
  exists so the stable part can hit Gemini's implicit prefix cache rather
  than being re-tokenized every turn.
- `gemini.ts` — the only file that knows the model vendor; isolates
  provider-specific quirks (no `system` role inside `contents`; tool
  results ride back as a `user` turn with `functionResponse` parts;
  `thoughtSignature` parts must be echoed back verbatim on replay; a
  blocked prompt returns HTTP 200 with no candidates, not an error status).
- `tools.ts` — the model's callable surface. The only state-changing tool
  is `propose_set_log`, and it does not write training data — see §4.1.

### 4.1 The propose → confirm pattern

This is the core safety property of the whole AI layer, restated precisely
because it's easy to weaken by accident in a future change:

1. The model calls `propose_set_log`, which inserts a `pending` row into
   `coach_proposals`. This is the *only* write path available to the
   model — no tool exists that writes to `session_sets` directly.
2. The client shows the proposal as a confirm card.
3. Confirming calls `/coach/confirm`, which is a plain deterministic
   function: read the pending proposal, write the sets, mark it
   `confirmed`. No model is invoked on this path.
4. The guard is `.eq("status", "pending")` on the update that claims the
   proposal — a double-tap or retried request finds it already resolved
   and changes nothing (verified against production: replaying a confirm
   changes 0 rows).

The model proposes; a deterministic, model-free code path executes. This
is what makes "the AI hallucinated something wrong" a UI-correctable
mistake (reject the card) rather than a corrupted training record.

## 5. Storage

One public bucket, `exercise-media`: static/animated WebP demo assets for
the 36 catalog movements, `10MB` per-object limit, public-read policy
(deliberate — generic catalog demos shared by every user are not personal
data, and public URLs avoid signed-URL expiry management), write access
restricted to the service role via the Storage dashboard/CLI only — no
client-side upload path exists or is planned.

## 6. Build & deploy

- **Client**: `flutter build apk --release` / `flutter build ios` from one
  codebase. Release Android build currently signs with the debug key (no
  release keystore configured yet — fine for sideloading, not for a Play
  Store upload; see Feature Ticket List if/when that matters).
  App icon and native splash generated from a single source mark via
  `flutter_launcher_icons` / `flutter_native_splash`, not hand-exported
  per-platform assets.
- **Database**: `supabase db query --linked -f path/to.sql` against the
  linked project; migrations applied in numeric order, never out of order.
- **Edge Function**: `supabase functions deploy coach`. `GEMINI_API_KEY`
  set as a function secret, never in client code or a committed file.

## 7. Known technical debt (detail in Feature Ticket List §C)

- No regression test (golden set) for the natural-language log parser —
  the one part of the system that can silently corrupt real training data
  on a bad prompt-engineering change.
- Coach replies are single-shot JSON, not streamed — longer answers read
  as slow.
- Context caching relies on implicit prefix-matching only; explicit
  `cachedContents` hasn't been evaluated against real prompt sizes.
- Single AI provider (Gemini) with no fallback — an acceptable v1 risk per
  PRD §11, not yet revisited.
- Chat history is a hard 12-turn window with no summarization; long
  threads lose earlier context outright.

## 8. Architectural decisions worth stating explicitly

- **RLS is the authorization layer, not an app-layer check.** Every
  user-owned table gets the same single-predicate policy
  (`user_id = auth.uid()`, or `id = auth.uid()` for `profiles`) via one
  generated loop in `0003_v2_schema.sql`, not per-table bespoke policies.
  New tables should join that loop, not invent a new pattern.
- **`security invoker` is the default; `security definer` is the
  exception and must be justified.** Only two functions break this:
  `handle_new_user()` (a trigger needing elevated privilege to provision a
  new signup's rows — standard, safe) and `bootstrap_user_program(uuid)`
  (not currently self-validating its `p_user_id` argument — a real gap,
  covered in the Security & Access document, not this one).
- **Comparisons match on stable identity, not row id.** `program_days`
  rows are regenerated on every re-plan; the day's `label` ("Push Day") is
  what's stable, so historical comparison matches on label, not id
  (`HANDOFF.md` bug #12 — the failure mode was silently returning null,
  not a wrong number, "the failure mode that hides longest").
- **One session per local calendar day**, resolved via
  `open_session_for_today`'s lookup-then-create, not a database unique
  constraint — deliberate, since the lookup already has to happen for the
  common "reuse the open session" path, and a constraint would only add a
  second way to fail the same case.
- **No synthetic data ships as if real**, including in RPC responses — a
  hasNext:false / null / empty-array response is preferred over a
  plausible-looking fake row, all the way through the stack (PRD principle
  8).

---

*Next: `05-security-and-access.md`.*
