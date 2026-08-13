# LOAD v2 — screen ↔ data contracts (cross-validation)

**Status:** written by walking each of the six design screens against (a) the
existing schema `migrations/0001–0018` and (b) the planned `migrations_v2/`
set, item by item: what the screen reads, what it writes, where that lives,
and whether the same fact serves other screens consistently. Findings —
including gaps in my own migration plan — are at the bottom and folded back
into `08-v2-build-plan.md`.

Legend per row: ✅ covered by existing schema · 🆕 covered by a planned v2
migration · ⚠️ gap found (see Findings).

---

## 1. Onboarding

### Reads

| Screen needs | Source | Status |
|---|---|---|
| Goal options (5 fixed) | client constant (they're product copy, not data) | ✅ |
| Body-map nodes: position, view, laterality | `joints.map_view/map_x/map_y/is_lateral` | 🆕 v2_0002 |
| Bar types (20/15/10) and plate sizes | client constants mirroring `plate_sizes_kg` default | ✅ |
| Split suggestion from day count | pure function of `training_weekdays` count — client-side, mirrored in generation SQL | ✅ |
| Plan-ready screen: sessions per day, exercises, loads | plan generation output (`programs` → `program_days` → `program_day_exercises`, `scheduled_workouts`) | ⚠️ **F2** — generation must change |

### Writes

| User answer | Lands in | Status |
|---|---|---|
| email / password | Supabase Auth | ✅ |
| goals (ordered) + "you choose" | `training_profiles.goals`, `.goal_is_coach_choice` | 🆕 v2_0001 |
| bodyweight | `body_measurements` (upsert, today) — same table the weigh-in flow and Progress panel 5 use, so onboarding's number **is** the first weigh-in | ✅ |
| target direction + kg | `.target_direction`, `.target_weight_kg` | 🆕 v2_0001 |
| training weekdays | `.training_weekdays` | 🆕 v2_0001 |
| bench experience | `.has_benched` | 🆕 v2_0001 |
| bar type | `.bar_weight_kg` | 🆕 v2_0001 |
| plate inventory | `.plate_sizes_kg` | 🆕 v2_0001 |
| **calibrated bench start** (bar + plates loaded in step 4) | ⚠️ **F1 — nowhere.** It's an ephemeral computation (`barTotalKg`) that must reach `program_day_exercises.target_weight_kg` for bench at generation time | ⚠️ |
| body-map flags (joint, side) | `user_constraints (joint_id, side)` | ✅ |
| free-text "in your own words" | `user_constraints (joint_id NULL, label)` | ✅ |
| units | `user_preferences.units` | ✅ |

### Cross-screen checks

- Bodyweight → `body_measurements` → read identically by Train (fuel card),
  Progress panel 5, and the protein target (`protein_target_for` = 1.8 g/kg,
  matching the design's constant). **One fact, four consumers, one table.** ✅
- Injury flags → `user_constraints` → read by session-flow injury banner
  (`exercise_joints` join), Profile "Working around" row, and trainer-note
  receipts ("Shoulder flagged"). Compatible everywhere. ✅
- Plate inventory → read by Profile (editable), progression suggestions, and
  plan generation. ⚠️ **F3** — nothing *enforces* loadability yet.

---

## 2. Session flow

### Reads

| Screen needs | Source | Status |
|---|---|---|
| Today's exercises + sets/reps/rest/load | `program_day_exercises` via the Train-tab RPC (shared — the session screen is entered *from* Train, same payload) | ✅ |
| Set-1 prefill "from last time" | previous session's sets for the same exercise — `today_plan`'s `prefill_kg` pattern carries over to the new RPC | ✅ |
| Set-N prefill from set N−1 today | client state (uncommitted) | ✅ |
| Form cues | `exercise_cues` | ✅ |
| Form clip | `exercise-media` bucket via `demo_path` | ✅ |
| Rest duration per lift | `program_day_exercises.rest_seconds` | ✅ |
| **Weight step per lift** (±2.5 barbell, ±2 dumbbell, none bodyweight) | ⚠️ **F4 — no column, no rule.** Barbell step should be 2 × smallest plate owned; dumbbell step is an equipment property | ⚠️ |
| Effort-prompt frequency, auto-rest | `user_preferences` | 🆕 v2_0001 |
| Finish-screen "next session" note | progression RPC (same one Train's "these go up" uses) | 🆕 v2_0010 |

### Writes

| Event | Lands in | Status |
|---|---|---|
| Session open/close, elapsed | `workout_sessions` (`started_at`/`completed_at` → "48 min") | ✅ |
| Each set {kg, reps} | `session_sets` | ✅ |
| Effort answer (per lift) | v2_0003 per D1 — recommended: map onto `session_sets.rir` (easy→3, right→1, all→0) so the Progress histogram and stall detection read one column | 🔶 blocked D1 |
| Entry mode + unconfirmed flag | `session_exercises` columns | 🔶 blocked (v2_0003) |
| "Today feels off" situation | `workout_sessions` column | 🔶 blocked (v2_0003) |
| Rest-timer survival (D4) | `rest_started_at`, `rest_total_seconds` on `workout_sessions` | 🔶 goes in v2_0003 |
| Added/removed sets vs plan | derivable: actual set count vs `sets_target` via `program_day_exercise_id` link | ✅ |

Note carried from extraction: a planned set the user explicitly *skips* in the
bulk sheet never becomes a row — indistinguishable from "never got there."
Design-level gap, accepted for v1; the `unconfirmed` flag covers the
trust-of-data case that actually matters.

### Cross-screen checks

- Effort answer feeds **three** consumers: Progress histogram (panel 3), stall
  detection ("your effort answers"), progression reasons ("two reps left").
  All three read `session_sets.rir` under the D1 recommendation — consistent. ✅
- The finish screen's forward-looking note and Train's after-state "next time
  these go up" are the same computation — one RPC, two screens. ✅

---

## 3. Train tab

### Reads

| Screen needs | Source | Status |
|---|---|---|
| Today's plan (before-state) | new Train RPC (replaces `today_plan`) | 🆕 v2_0010 |
| Morning note + receipts + ack state | `coach_messages` (+category/needs_attention/acknowledged_at) + `coach_message_receipts` | 🆕 v2_0004 |
| **Who writes the morning note, and when** | ⚠️ **F5 — no generation mechanism planned.** Needs cron (pg_cron → Edge Function) or generate-on-first-open; the `notify_morning_note` preference implies it must exist *before* the app opens | ⚠️ |
| 7-day streak strip | `workout_sessions.performed_on` (trained) + `scheduled_workouts` (planned) + pause exclusion | ✅ + 🆕 v2_0006 |
| After: session hero (volume, sets, time) | `v_session_totals` | ✅ |
| After: "vs last push" delta | `last_same_day_totals()` — label-matched, exactly the design's semantics ("last push", not "last week") | ✅ |
| After: six-session trend | last 6 same-label sessions with volume | 🆕 v2_0010 |
| After: per-exercise volume bars + muscle chips | `session_sets` grouped + `exercise_muscles` | ✅ |
| After: PB callout ("most reps at this weight or above") | historical max-reps-at-≥weight query | 🆕 v2_0010 |
| After: "next time these go up" + reasons | extended `coach_next_load` returning reason + delta, **snapped to loadable weights** | 🆕 v2_0010 + ⚠️ F3 |
| Protein row + quick-add | `nutrition_entries`, `nutrition_targets`, `v_nutrition_daily` | ✅ |
| Tomorrow / rest-tomorrow / "then Fri" | `scheduled_workouts` (next two pending) | ✅ |

### Writes

| Event | Lands in | Status |
|---|---|---|
| "Got it" / Reply on morning note | `coach_messages.acknowledged_at` — same field the Trainer tab reads, so the badge clears everywhere at once | 🆕 v2_0004 ✅ |
| +20g / +30g protein | `nutrition_entries` insert | ✅ |

---

## 4. Progress tab

Every panel: reads only, plus a range parameter. **All v2_0009 RPCs take
`p_since date`** derived from the 8wk/12wk/6mo/All control — noted as a hard
requirement on that migration.

| Panel | Data | Status |
|---|---|---|
| 1 — Strength tiles | `session_sets.e1rm_kg` per lift per session (top set), stepped | ✅ data · ⚠️ **F6**: which four lifts are "the" lifts? Needs a rule |
| 2 — Stuck | `lift_status()` classifier | 🔶 v2_0008, blocked D5 |
| 2 — "Ask about the squat" | opens Trainer tab; Edge Function's existing `coach_exercise_history` tool supplies the cited context | ✅ |
| 3 — Effort histogram | `session_sets.rir` bucketed 0–6+, working sets only | ✅ (populated once D1 lands) |
| 4 — Sets per muscle | `weekly_sets_by_muscle()` vs 10–20 band | 🆕 v2_0007 |
| 5 — Body | `v_bodyweight_trend` (raw + 7-day avg — already exists), `target_weight_kg` line, rate/week derived from the avg series | ✅ |
| 5 — Protein week | `v_nutrition_daily` vs `nutrition_targets` | ✅ |
| 6 — Showing up | sessions/week vs target (`training_weekdays` count), minus `paused_days_between()` | 🆕 v2_0001 + v2_0006 |
| 7 — Photos | `progress_photo_pair()` — weight joined from `body_measurements`, never duplicated | 🆕 v2_0005 |
| All — sufficiency gates | one RPC returning the raw counts (sessions/lift, RIR-answered sets, weigh-ins, weeks); client renders the gate copy | 🆕 v2_0009 |

---

## 5. Trainer tab

| Screen needs | Source | Status |
|---|---|---|
| Thread, day grouping, avatar collapsing | `coach_messages` ordered by `created_at` | ✅ |
| Eyebrow + amber styling | `category`, `needs_attention` | 🆕 v2_0004 |
| Receipts (snapshotted at write time) | `coach_message_receipts` | 🆕 v2_0004 |
| Unread divider | first `assistant` row with `read_at IS NULL` | 🆕 v2_0004 |
| Pinned note | `pinned_until >= today` | 🆕 v2_0004 |
| Decision buttons ("Go to 45 kg" / "Hold") | `coach_proposals` kind `adjust_program` | ✅ schema · ⚠️ **F7**: `/coach/confirm` only executes `log_sets` today — the Edge Function must implement `adjust_program` (write forward `target_weight_kg`) |
| Resolved strip ("Noted at 7:14") | `coach_proposals.resolved_at` + `acknowledged_at` | ✅ |
| Search with topic tags ("Shoulder", "Bench") | trigram index 🆕 v2_0004 · tag rendered from `category` for v1 (a per-message free `topic` would be better; deferred — F8, minor) | 🆕/⚠️ |
| Free-text chat | existing coach Edge Function | ✅ |
| Debrief / missed-session / weekly-review notes | same generation mechanism as F5 — one decision covers all four message types | ⚠️ F5 |

---

## 6. Profile tab

| Item | Source / target | Status |
|---|---|---|
| Instant preferences (rest, effort, toggles, notifications) | `user_preferences` columns, direct write | 🆕 v2_0001 |
| Plate inventory (instant) | `training_profiles.plate_sizes_kg` | 🆕 v2_0001 |
| Staged plan edits (goals/days/target) | client-side buffer per D3; diff vs current `training_profiles` row | ✅ by decision |
| "Rewrite my week" | plan-generation RPC — **same one onboarding calls** (F2). Verified compatible with "loads stay": generation already seeds loads from `max(top_weight_kg)` history before falling back to defaults, and the archive trigger (0010) cancels stale pending slots | ⚠️ F2 |
| Split shown as derived | pure function of `training_weekdays` — same client function as onboarding step 3 | ✅ |
| Pause / resume | `training_pauses` | 🆕 v2_0006 |
| "Working around" row | `user_constraints` (same rows onboarding wrote) | ✅ |
| "Your bar" row | `bar_weight_kg` | 🆕 v2_0001 |
| Stats (47 sessions · 12 weeks · 3.8/wk) | count/min-date over `workout_sessions` + the panel-6 rate | ✅ |
| Export / delete account | existing F2 legal-flow tickets; export = "every set, as a spreadsheet" is a straightforward query-to-CSV | ✅ tracked |

---

## Findings

**F1 — The calibrated bench start has no path to the plan.** Onboarding's step
4 produces `barTotalKg` (or bar-only for never-benched); plan generation must
receive it and write it to bench's `target_weight_kg`. Fix: pass it as a
parameter to the generation RPC (no new column — it's an input to generation,
not a durable profile fact; the durable facts are `bar_weight_kg` +
`has_benched`, already stored).

**F2 — `bootstrap_user_program` must be rewritten, as its own migration.**
Four changes: schedule onto `training_weekdays` (not every-2-days); branch on
`has_benched = false` (bar-only 5×5 week one); accept the F1 starting load;
key off `goals[1]`. It already carries loads from history on regen, which is
what makes Profile's "Rewrite my week — loads stay" work. Added to the plan as
**`v2_0011_plan_generation.sql`**.

**F3 — Nothing enforces loadability.** The plate-inventory promise ("I will
never ask you to load a weight you cannot build") needs a
`snap_to_loadable(p_user_id, kg)` SQL function — bar + 2×(multiset of owned
plates), snap down — used by both progression suggestions (v2_0010) and
generation (v2_0011). Without it the promise is decoration.

**F4 — No per-exercise weight step.** The session steppers and "easy → +one
step" logic need it. Fix: `exercises.weight_step_kg` (dumbbell 2.0, machine
2.5/5, bodyweight NULL) with barbell lifts *derived* as 2 × smallest owned
plate, falling back to the column. Small addition → folded into v2_0003.

**F5 — New decision D7: how trainer notes get generated.** Morning note,
debrief, missed-session, weekly review — four scheduled/triggered generations,
no mechanism planned. Options: pg_cron → Edge Function (real push, notes exist
before open; more moving parts) vs generate-on-open (simple; but then
notification toggles are a lie). Debrief can piggyback on session completion
either way. Needs a call before Phase 2.

**F6 — New decision D8 (small): which lifts get strength tiles.** Recommend:
the weighted compound lifts in the current program, by frequency, capped at 4 —
no new schema, one query.

**F7 — Edge Function work item: implement `adjust_program` confirm.** Schema
already supports it; `/coach/confirm` doesn't. Phase 5 scope, keeping the
propose→confirm invariant (model proposes, deterministic path executes).

**F8 — (minor) search-result topic tags.** v1: render from `category`. A
free-text `topic` column can come later without breaking anything.

**F9 — Trainer message card content (stat tiles, inline sparkline).** Caught on
a second pass over the four Trainer scenarios: the weekly review carries stat
tiles and the stalled-lift note an inline chart, and v2_0004 had no field for
either. Fixed: `coach_messages.card jsonb`, snapshotted at write time like
receipts. The decision buttons themselves need no schema — their labels ride in
`coach_proposals.payload`, and "Hold for now" is a reject with a resolved note.

**Sub-screen coverage note.** The contracts above were validated against every
state in each file, not just the default view: onboarding auth → 6 steps →
building → plan-ready (incl. its rest-day variant); Train before / after /
after-rest-tomorrow; session flow lift (×4 exercises) / choose-mode / bulk
sheet / situation sheet / review / done; all four Trainer scenarios incl. the
injury sore/sharp branches; Profile's six sheets + paused state; Progress's
seven panels in both populated and gated states.

### What cross-validated clean

The load-bearing cross-screen facts all resolve to single sources: bodyweight
(4 consumers, 1 table), injury flags (3 consumers, 1 table), effort (3
consumers, 1 column), acknowledgement (2 tabs, 1 field), progression
suggestion (2 screens, 1 RPC), protein target (3 screens, 1 versioned table).
No screen requires a fact another screen stores differently.
