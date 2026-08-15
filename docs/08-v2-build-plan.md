# LOAD v2 — build plan from the design handoff

**Status:** written after reading all six design files end-to-end (state shapes
and derived-value logic extracted from each `Component` class) and
cross-referencing every requirement against the schema actually in
`supabase/migrations/0001`–`0018`. This is the "what do we need before we start
coding" document.

---

## 1. Verdict: extend the schema, don't rebuild

The v2 design is a **complete UI/UX rewrite** but only a **partial data-model
change**. Roughly 70% of what the new screens need is already in the database,
built and unused. Starting a fresh Supabase project would throw that away for
no gain.

What the new design needs that **already exists**:

| v2 design requirement | Already in schema |
|---|---|
| Effort / RIR histogram (Progress panel 3) | `session_sets.rir` (0–10) and `.rpe` |
| **Warm-up vs working sets** — the design's own open decision #1 | `session_sets.kind` enum already has `'warmup'`. **Already solved.** |
| est. 1RM strength tiles (Progress panel 1) | `session_sets.e1rm_kg` — stored generated column |
| Weekly sets per muscle (Progress panel 4) | `exercise_muscles` with `role` + `contribution` |
| Body-map injury flags with left/right | `user_constraints.side` + `joint_id` + nullable `joint_id` for free text |
| Session → exercise → set logging | `workout_sessions` / `session_exercises` / `session_sets` |
| "vs last push" volume delta (Train tab) | `last_same_day_totals()` — already matches by **label**, not id |
| Stall-decision actions ("Go to 45 kg" / "Hold") | `coach_proposals` + `proposal_kind = 'adjust_program'` (declared, never implemented) |
| Trainer chat thread | `coach_threads` / `coach_messages` |
| Daily bodyweight, one per day | `body_measurements` (unique on user+date, upserted) |
| Protein log + versioned target | `nutrition_entries` / `nutrition_targets` |
| Per-exercise rest seconds, rep range | `program_day_exercises.rest_seconds`, `.rep_low`, `.rep_high` |
| Pain reports | `session_pain_reports` |

The existing schema was built well ahead of the old UI. The v2 design has
caught up to it.

## 2. What is genuinely new

Grouped by what forces the change, not by screen.

### 2.1 Onboarding captures things the profile can't hold

- **Multiple ranked goals.** `training_profiles.goal` is a single enum; the
  design is an ordered multi-select where the first pick "leads".
- **"I don't know — you choose"** is a *distinct answer*, not an empty one. It
  must survive as its own value.
- **Bodyweight target is tri-state**: unanswered / directional target /
  explicitly declined. A nullable `target_weight_kg` can't tell "not asked yet"
  from "user declined to set one" — and the design is emphatic that declining
  is a legitimate answer, not a gap.
- **Bar type** (20 / 15 / 10 kg) and **plate inventory** (which plate sizes the
  gym actually has). Together these decide which loads are even *loadable* —
  the app must never prescribe 42.5 kg to someone with no 1.25s.
- **"Never benched"** as a branch, distinct from experience level. An
  intermediate lifter can still have never benched. It triggers a bar-only
  technique week.
- **Which weekdays**, not just how many. `programs.days_per_week` is a count;
  the streak strip and schedule need the actual days.
- **More body-map nodes.** Current joints: shoulder, elbow, wrist, knee, hip,
  lumbar, ankle. The design's map also has neck, upper back, shoulder blade,
  glute, hamstring, calf.

### 2.2 The session flow records *how* data was entered

This is the subtle one and it matters for data quality.

- **Effort is asked once per lift**, not per set, as a three-way qualitative
  answer. `session_sets.rir` is per-set and numeric.
- **Entry mode per exercise** — logged live, deferred to the end, or bulk
  filled — plus an **unconfirmed** flag. In "log at the end" mode, any lift the
  user never touches is **auto-saved at planned weight × top of rep range**.
  Those sets are guesses the user passively accepted. They must not be
  indistinguishable from sets someone actually measured, or the effort
  histogram and progression logic are reading fabricated data.
- **Session "situation"** — today feels off: short on time / low energy / pain
  / equipment / feeling strong. It changes prescribed sets and weight for the
  whole session, so it has to be recorded alongside the result.

### 2.3 Trainer messages are richer than chat

- **Receipts** — the "what I read" chips. These cite point-in-time facts
  ("2-day streak", "shoulder flagged") that drift. They must be **snapshotted
  when the message is written**, not recomputed at display time, or an old note
  will silently start citing today's numbers.
- **Unread / acknowledged / pinned** state, and a **category + warn flag** per
  message. Acknowledgement is an explicit action, separate from having read it.
- **Archive search** over the full history.

### 2.4 Progress needs things nothing currently produces

- **Progress photos** — no table, no bucket. Two slots, each pairing a date
  with the bodyweight on that date.
- **Stall detection** — the highest-value panel in the whole design and the one
  piece of genuinely new logic: a lift is stalled when top-set load hasn't
  increased across N sessions *while the user is completing the top of the rep
  range*. Needs to be a real function, not a client-side guess.
- **Per-panel data-sufficiency gates** — 3 sessions per lift, 8 RIR-answered
  sets, 7 weigh-ins, 3 weeks of history, 1 full week of training. Every panel
  explains what it needs instead of drawing a chart from two points.
- **Muscle display grouping mismatch.** Panel 4 wants Chest / Back / Quads /
  Hamstrings / Shoulders / Arms. The schema groups quads, hamstrings, glutes
  and calves all under `legs`. The granular muscles exist; the display grouping
  doesn't.

### 2.5 Profile needs preferences and pause

- **Instant preferences**: default rest, effort-ask frequency, auto-start rest,
  keep screen awake, rest-end sound, four notification toggles. `user_preferences`
  currently holds only `units`.
- **Pause training** needs **date ranges**, not the design's single boolean.
  "Weeks off don't count against your consistency" is a query over date ranges —
  a boolean can't express which weeks to exclude.

## 2.6 Table-by-table inventory: cut / add / adopt

### Adopt unchanged — 17 of 30 tables

These need no migration at all. They already model exactly what v2 asks for.

| Table | Why it survives untouched |
|---|---|
| `profiles` | Identity + timezone. `user_today()` depends on the timezone for every streak and daily rollup. |
| `exercises` | The catalog, incl. `demo_path` (0016) for the form clips. |
| `exercise_muscles` | `role` + `contribution` → Progress panel 4. |
| `exercise_joints` | `stress_level` → the injury flag on a lift during a session. |
| `exercise_equipment` | Still needed for "can this be done with what you have". |
| `exercise_cues` | The cue list that opens on set 1. |
| `exercise_alternatives` | The swap. |
| `user_constraints` | **`side` (left/right/bilateral) + nullable `joint_id`** — the body map's laterality *and* its free-text note, already modelled. |
| `programs` | Program identity, split, status. |
| `program_days` | "Push day" as a row, matched by label across re-plans. |
| `program_day_exercises` | `sets_target`, `rep_low/high`, `rest_seconds`, `target_weight_kg` — every number the session screen prefills from. |
| `scheduled_workouts` | The 7-day ribbon and the tomorrow/then preview. |
| `session_sets` | **`kind` (incl. `'warmup'`), `rir`, `rpe`, `e1rm_kg`, `volume_kg`** — the effort histogram and strength tiles read straight off this. |
| `session_pain_reports` | Typed, joint-referencing pain. |
| `body_measurements` | One row per day, upserted → the daily-dot + 7-day-average chart. |
| `nutrition_entries` / `nutrition_targets` | Protein log and versioned target. |
| `coach_threads` / `coach_proposals` | Thread, and `proposal_kind='adjust_program'` for the stall decision buttons. |

### Adopt with added columns — 6 tables

| Table | Added | Migration |
|---|---|---|
| `training_profiles` | goals[], goal_is_coach_choice, target_direction, training_weekdays, bar_weight_kg, plate_sizes_kg, has_benched | `v2_0001` |
| `user_preferences` | 9 preference columns (rest, effort prompt, auto-rest, awake, sound, 4 notification toggles) | `v2_0001` |
| `joints` | map_view, map_x, map_y, is_lateral + 6 new rows | `v2_0002` |
| `muscles` | display_group | `v2_0007` |
| `coach_messages` | category, needs_attention, read_at, acknowledged_at, pinned_until | `v2_0004` |
| `workout_sessions` / `session_exercises` | situation / effort + entry_mode + unconfirmed | `v2_0003` *(blocked)* |

### Must change — one breaking issue

**`training_profiles.experience` and `.environment` are `NOT NULL`, and the v2
onboarding asks for neither.**

The v2 intake is: goal → bodyweight → days → bench → body map → review. There is
no experience question and no "what kind of gym" question. Inserting a v2 profile
against the current table fails outright.

This is not an oversight in the design — it's the thesis ("never ask for
something it can work out") applied correctly. v2 replaced both with better
proxies:

- *experience* → `has_benched`, which is the thing that actually changes week one
- *environment* → bar weight + plate inventory, which is strictly more specific
  than "commercial gym" and is what load prescription actually needs

**Fix:** drop the `NOT NULL` on both, and have plan generation default them
(`has_benched = false` → beginner; bar + plates present → commercial_gym). Goes
in `v2_0003` alongside the session columns.

### Becomes dormant — keep, stop using

Not dropped. Dropping costs a migration and buys nothing, and two of these are
one product decision away from mattering again.

| Thing | Why it goes quiet |
|---|---|
| `train_environment` enum + `environment_equipment` | v2 stops asking. Keep the table so `bootstrap_user_program`'s catalog filter still runs against a defaulted value. |
| `experience_level` enum | Same — defaulted, never asked. |
| `program_blocks` | Unused in v1, unused in v2. Still the right home for periodisation. |
| `coach_memories` | Written by the Edge Function; the v2 Trainer tab has no UI for it. |
| `v_weekly_muscle_volume` | Superseded by `weekly_sets_by_muscle()` — v2 counts *sets*, not tonnage, and needs `display_group`. |

### Replace — the RPC layer and the client

| Replace | With | Why |
|---|---|---|
| `today_plan()` | A Train-tab RPC | v2's Train tab is a different shape: morning note + receipts, or the after-state with volume bars, six-session trend, PB, progression reasons. `today_plan` returns the v1 Today screen. |
| `next_session_preview()` | Folded into the same RPC | v2 wants tomorrow *and* "then · Fri · Leg day". |
| `coach_next_load()` | Extended | Needs to return a **reason string** ("Two reps left on the last set") — the design never shows a number without its reason. |
| Everything in `lib/screens/` | Rewritten | Six new screens, dark theme, new nav. This is the bulk of the work. |
| `lib/theme/app_colors.dart` | Rewritten | Warm cream → `#100E0D` / lime `#C8F751`, Space Grotesk. |
| `docs/06-frontend-specification.md` | Superseded | Describes the light warm design. |

### Genuinely new — 3 tables, 1 bucket

`progress_photos` + private bucket · `coach_message_receipts` ·
`training_pauses`. Everything else v2 needs is a column on something that
already exists.

---

## 3. Migration plan

New migrations live in **`supabase/migrations_v2/`**, numbered `v2_0001`
upward, kept separate from `migrations/0001`–`0018` so the v2 work reads as one
coherent change set. They are **additive** — no table is dropped, no column is
removed, and existing training history survives intact.

| File | What it does | Blocked on a decision? |
|---|---|---|
| `v2_0001_profile_and_equipment.sql` | Ranked goals, target tri-state, bar weight, plate inventory, bench experience, training weekdays, preference columns | No |
| `v2_0002_body_map_joints.sql` | Seeds the extra body-map joints (neck, upper back, shoulder blade, glute, hamstring, calf) | No |
| `v2_0003_session_provenance.sql` | Per-lift effort answer, entry mode, unconfirmed flag, session situation | **Yes — D1, D2** |
| `v2_0004_trainer_messages.sql` | Receipts, unread/ack/pinned, category, warn, search index | No |
| `v2_0005_progress_photos.sql` | Photos table + private storage bucket | No |
| `v2_0006_training_pauses.sql` | Dated pause ranges + consistency exclusion | No |
| `v2_0007_muscle_display_groups.sql` | Display-group column + backfill for panel 4 | No |
| `v2_0008_stall_detection.sql` | `lift_status()` — the stall/progressing classifier | **Yes — D5** |
| `v2_0009_progress_rpcs.sql` | Per-panel aggregations + data-sufficiency gate counts (all take `p_since` for the range control) | No |
| `v2_0010_train_tab_rpcs.sql` | Train-tab RPC, six-session trend, PB detection, progression suggestions with reasons, `snap_to_loadable()` | **Yes — D5** |
| `v2_0011_plan_generation.sql` | `bootstrap_user_program` rewrite: schedule onto `training_weekdays`, `has_benched=false` bar-only branch, calibrated bench start as a parameter, lead-goal keying. Serves onboarding **and** Profile's "Rewrite my week" | **Yes — D6** |

Added after the screen-by-screen cross-validation (`09-v2-screen-data-contracts.md`),
which also surfaced: `exercises.weight_step_kg` (folded into v2_0003), the
`snap_to_loadable()` plate-constraint function (v2_0010), and an Edge Function
work item — `/coach/confirm` must learn to execute `adjust_program` proposals
(Phase 5).

## 4. Decisions

> **Decided 2026-08-13: D1–D8 all resolved as recommended** (founder sign-off in
> session). The per-decision text below is kept verbatim as the record of the
> options considered, so any future amendment starts from the reasoning rather
> than re-deriving it. Amend by striking the recommendation and dating the change.

These change the schema, so they're worth settling first. Four are the design
team's own flagged open questions; two I found while cross-referencing.

**D1 — Effort: per lift or per set?** *(design's open decision #4)*
The design asks once per lift after set 1 — low friction, one data point per
exercise. The Progress histogram would be sharper per-set. The schema differs:
a column on `session_exercises` vs populating `session_sets.rir` on every set.
*My recommendation: keep per-lift as designed, and map the three answers onto
the existing `rir` column on the sets they cover (easy → 3, right → 1, all → 0).
That way the histogram reads from one place and we can go per-set later without
a migration.*

**D2 — Warm-up sets.** *(design's open decision #1)*
`session_sets.kind` already supports `'warmup'`, but the design has **no UI for
marking one**, so every logged set will be `'working'` and warm-ups will skew
both volume and the effort histogram — exactly what the design doc warns about.
Either we add a warm-up affordance to the session screen (design change), or we
accept the skew for v1. *My recommendation: accept for v1, but exclude
`kind <> 'working'` in every aggregate now so turning it on later needs no
backfill.*

**D3 — Do staged plan edits survive an app restart?**
The Profile tab's "nothing is saved until you look at it" implies a pure
client-side edit buffer. If the user edits their training days, backgrounds the
app, and comes back — do the pending edits still exist? *My recommendation:
client-side only for v1. No table. Cheapest thing that matches the copy.*

**D4 — Rest timer in the background.** *(design's open decision #2)*
If it must survive backgrounding and fire a notification, the session needs a
persisted `rest_started_at` / `rest_seconds`, plus local-notification
scheduling. *My recommendation: persist it — a rest timer that dies when you
answer a text is a bug users will report on day one.*

**D5 — Stall detection parameters.** The design cites two different framings:
"5 sessions at 60 kg while finishing the top of the rep range three times" and
"no direction in six weeks". I need the actual rule: N sessions, and whether
top-of-range completion is a required condition or just supporting evidence.
*My recommendation: stalled = top-set load unchanged across ≥3 sessions of that
lift AND top of rep range completed in ≥2 of them. Both parameters live in SQL
so they're tunable without a client release.*

**D6 — Do multiple goals change plan generation, or are they just recorded?**
`bootstrap_user_program` keys off one goal. Multi-goal is easy to *store* and
much harder to *act on*. *My recommendation: store all, generate from the lead
goal only, for v1.*

**D7 — How do trainer notes get generated?** *(from cross-validation, F5)*
Morning note, session debrief, missed-session nudge, weekly review — four
scheduled or triggered generations with no mechanism planned. Either pg_cron
invokes the coach Edge Function on a schedule (notes exist before the app
opens, notifications are real, more moving parts) or the client generates on
first open of the day (simple, but then the notification toggles do nothing).
The debrief can piggyback on session completion either way. *My
recommendation: on-open generation for v1, cron when notifications ship — the
preference toggles are already in the schema either way.*

**D8 — Which lifts get the four strength tiles?** *(from cross-validation, F6)*
*My recommendation: the weighted compound lifts in the current program,
ordered by times trained, capped at four. No schema needed.*

## 5. Build order

Seven phases. Each is shippable and testable on its own; nothing depends on a
later phase.

**Phase 0 — Foundations (no UI).** Migrations `v2_0001`, `0002`, `0004`–`0007`.
Theme rewrite: the whole app goes dark (`#100E0D` page, `#C8F751` lime accent,
Space Grotesk). New nav shell — 4 tabs with the expanding pill. This is a pure
find-and-replace of `AppColors` plus one new nav widget, and it unblocks every
screen after it.

**Phase 1 — Session flow.** The most complex screen and the one that produces
all the data everything else reads. Migration `v2_0003`. Three entry modes,
adjustable set chips, per-lift effort, rest timer, finish screen.
*Build this before Progress or Train, because both of those are just views over
what this writes.*

**Phase 2 — Train tab.** Before / after / after-with-rest states. Reuses
`last_same_day_totals`. Migration `v2_0010`.

**Phase 3 — Onboarding.** Six steps, body map, plate loading. Big surface area,
low logical risk, and only new users hit it — which is why it's not first
despite being screen one.

**Phase 4 — Progress tab.** Migrations `v2_0008`, `0009`. Seven panels, each
with its populated and gated state. Both states must be built.

**Phase 5 — Trainer tab.** Chat, receipts, pinned note, search. Depends on the
coach Edge Function learning to emit receipts and set message categories.

**Phase 6 — Profile tab.** Instant preferences vs staged plan edits, plate
inventory, pause.

## 6. Client-side architecture notes

The current client is one `AppState extends ChangeNotifier` with everything on
it. That was fine for four screens; it will not hold six screens with this much
per-screen state.

Recommended split, keeping `provider` (no new dependency):

- `SessionController` — the in-session flow. Owned per session, disposed on
  finish. Holds set arrays, effort answers, rest countdown, entry modes.
- `PlanController` — program, schedule, today's prescription, staged plan edits.
- `ProgressController` — the seven panels' data, keyed by selected range.
- `TrainerController` — thread, unread, pinned note.
- `ProfileController` — preferences, plate inventory, pause.

Two rules worth keeping from what we already learned the hard way:

1. **No local mirror of server-derived state.** Every earlier bug in this
   project came from a client-side copy disagreeing with the server.
2. **One service layer.** `SupabaseService` stays the only file that imports
   the Supabase client.

**Also worth doing during the rewrite:** the design's own contrast rule says
`#5C5450` and darker on `#1B1817` fails WCAG AA and "was a real defect caught in
review". Every status in the design already pairs colour with an icon *and* a
word — that discipline should be enforced in the shared widgets, not
per-screen, so it can't regress.

## 7. What I need from you to start

Answers to D1–D6 above. D2 and D5 matter most: D2 decides whether the effort
histogram is trustworthy, and D5 is the highest-value panel in the design.

Everything in Phase 0 can start immediately — none of it is blocked on those
answers.
