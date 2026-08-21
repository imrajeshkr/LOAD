# Adaptive load progression — design

**Issue #1.** Today the session set-editor prefills a lift at *last session's exact
weight × the top of the rep range* — flat, no progression, and it ignores how
hard the last session actually was. This designs an adaptive prefill grounded in
established progressive-overload practice.

## Goal

When a lifter starts a lift, the prefilled weight × reps should be a sensible
*next target* derived from their own last performance — nudging reps up before
weight, bumping weight only when they've earned it, holding when they ground
out, and starting conservatively when there's no history. It must self-correct
when the lifter does more or less than suggested.

## The method: double progression + RIR autoregulation

Two well-established ideas, combined:

1. **Double progression (reps before weight).** Work inside the prescribed rep
   range. Keep the weight and add reps session to session until you reach the
   *top* of the range; only then add the smallest loadable weight and drop back
   toward the bottom. This is the standard hypertrophy/strength progression for
   non-novices and is gentle on load — weight moves rarely, reps move often.

2. **RIR autoregulation.** Reps-in-reserve (our per-lift effort answer:
   easy→RIR 3, right→1, all→0) gauges readiness. Leaving reps in the tank means
   push; grinding the last rep means hold. RIR *is* the personalization — the
   "how much before increasing" that varies per person falls out of it, rather
   than a fixed session count.

Self-correction is inherent: the prefill is recomputed each session **from the
last actual top set + effort**, so exceeding the target (hit top of range) bumps
weight next time, and falling short (fewer reps) holds weight and lowers the rep
target — no separate "did they meet it?" bookkeeping.

## Algorithm

Per exercise, from the **last completed session's working sets**:

- `top_kg` — heaviest working weight
- `top_reps` — best reps achieved at `top_kg`
- `last_rir` — RIR of the final working set (falls back to effort mapping)
- `unconfirmed` — was last session auto-filled (deferred / `is_unconfirmed`)
- `rep_low`, `rep_high` — today's prescribed range
- `step` — `resolved_weight_step`, snapped to loadable plates

Produce `(prefill_kg, prefill_reps)`:

| # | Condition | prefill_kg | prefill_reps | Why |
|---|-----------|-----------|--------------|-----|
| 1 | no history | plan target | `rep_low` | conservative first exposure |
| 2 | `unconfirmed` | `top_kg` | `rep_low` | don't build on an auto-filled guess |
| 3 | ground out (`effort='all'` or `last_rir=0`) | `top_kg` | `top_reps` | repeat — earn it before moving |
| 4 | hit top (`top_reps >= rep_high`) **and** `last_rir >= 1` | `snap(top_kg + step)` | `rep_low` | graduated the range → add weight, reset reps |
| 5 | reps to spare (`last_rir >= 2` or `effort='easy'`), below top | `top_kg` | `min(top_reps + 2, rep_high)` | easy day → add two reps |
| 6 | otherwise (mid-range, normal effort) | `top_kg` | `min(top_reps + 1, rep_high)` | steady one-rep climb |

Weight only ever rises in rule 4 (top-of-range with something left), so load
climbs deliberately; reps carry the week-to-week progression. Conservative by
construction.

## Where it lives

- **DB — `train_screen()`** (`v2_0010`): replace the current
  `prefill_kg = last set weight` / `prefill_reps = rep_high` with the table
  above, computed from a last-session CTE (the same shape
  `progression_suggestions` already uses). Single source of truth; the Progress
  "next time these go up" card and the session prefill then agree.
- **Client — `session_controller.staged()`**: the reps default is currently
  `e.repHigh`; change it to `e.prefillReps` so the computed rep target flows
  through. Weight already flows via `planKg → prefillKg`. `last-set-today`
  overrides both once the lifter logs a set, unchanged.

No new tables. New migration `v2_0015` redefines `train_screen()`.

## Out of scope (future)

- Per-user tuning of the RIR thresholds / step size beyond `resolved_weight_step`.
- Deload logic after repeated stalls (the stall detector already surfaces it on
  Progress; acting on it automatically is separate).
