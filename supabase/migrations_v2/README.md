# v2 migrations

Schema changes for the v2 design handoff (`.local/design_handoff_load_app`).
Kept separate from `../migrations/` so the whole v2 change set reads as one
coherent unit rather than being interleaved with v1 history.

**These are additive.** Nothing is dropped, nothing is removed, existing
training history survives. `migrations/0001`–`0018` must all be applied first.

Run in numeric order. Each file is idempotent (`if not exists` / `on conflict do
nothing`) and safe to re-run.

| File | Status | Notes |
|---|---|---|
| `v2_0001_profile_and_equipment.sql` | ready | Goals, target tri-state, bar + plates, weekdays, preferences |
| `v2_0002_body_map_joints.sql` | ready | Extra joints + silhouette coordinates for the body map |
| `v2_0003_session_provenance.sql` | ready | D1/D2/D4: effort, entry mode, unconfirmed, situation, rest persistence, weight steps, NOT NULL fix |
| `v2_0004_trainer_messages.sql` | ready | Receipts, card payload, unread/ack/pinned, category, search |
| `v2_0005_progress_photos.sql` | ready | Photos table + private bucket + `progress_photo_pair()` |
| `v2_0006_training_pauses.sql` | ready | Dated pause ranges + `paused_days_between()` |
| `v2_0007_muscle_display_groups.sql` | ready | Display grouping + `weekly_sets_by_muscle()` |
| `v2_0008_stall_detection.sql` | ready | D5: `lift_status()` — serves Progress panels 1 and 2 |
| `v2_0009_progress_rpcs.sql` | ready | `effort_histogram()`, `consistency_weeks()`, `progress_gates()` |
| `v2_0010_train_tab_rpcs.sql` | ready | `snap_to_loadable()`, `resolved_weight_step()`, `train_screen()`, `session_summary()`, `progression_suggestions()` |
| `v2_0011_plan_generation.sql` | ready | `bootstrap_user_program` rewrite (weekday scheduling, never-benched branch, bench calibration param, F1 auth fix) |

**Not SQL, tracked for later phases:** trainer-note generation (D7, on-open —
Edge Function, Phase 2) and `/coach/confirm` executing `adjust_program`
proposals (F7 — Edge Function, Phase 5).

Decisions D1–D8 were resolved 2026-08-13 — the record, options and reasoning
live in `docs/08-v2-build-plan.md` §4. `docs/09-v2-screen-data-contracts.md`
maps every screen's reads/writes to these objects.
