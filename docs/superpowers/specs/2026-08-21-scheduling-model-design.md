# Persistent scheduling model + calendar day swap — design (#4, Option B)

Replace the implicit 14-day rotation with a persistent **weekday → session**
pattern and a rolling scheduler, so the split order is stored, editable by
drag-drop, survives a "Rewrite my week", and the calendar never runs out.

## Why (problems with today's model)

- The rotation is implicit: `bootstrap_user_program` writes 14 dated
  `scheduled_workouts` by cycling `slot % day_count` across the training
  weekdays. Nothing records "Wednesday = Legs".
- So a custom reorder has nowhere persistent to live, and a later regeneration
  silently reverts it.
- The calendar is only ever ~2 weeks deep and never extends.

## The model

### New table — `program_weekday_slots`

The pattern: for each training weekday, which session runs.

```
program_weekday_slots(
  program_id      uuid,
  user_id         uuid,        -- denormalised for single-table RLS
  weekday         smallint,    -- ISO 1..7
  program_day_id  uuid,        -- which Push/Pull/Leg
  primary key (program_id, weekday)
  fk (program_id, user_id) -> programs
  fk (program_day_id, program_id) -> program_days
)
```
RLS: `user_id = auth.uid()`, all four verbs.

### Horizon + rolling top-up

- `SCHEDULE_HORIZON = 35 days`. Scheduled workouts always exist from today
  through today+35.
- `ensure_schedule(p_user_id)` (volatile): for the active program, insert a
  `scheduled_workouts` row for every date in `[today, today+35]` whose weekday
  is in `program_weekday_slots`, `on conflict (user_id, scheduled_for, …) do
  nothing`. Idempotent top-up.
- Called by the client **fire-and-forget after** `fetchTrainScreen` (today +
  the near-term rows already exist from generation, so the current load never
  waits on it; the horizon just stays filled for next time). No cron.

### `bootstrap_user_program` changes

1. After building `program_days`, (re)populate `program_weekday_slots` for the
   new program: training weekdays ascending, `program_day` cycling
   `slot % day_count` — the same default order as today.
2. Replace the inline 14-day loop with: delete future `scheduled_workouts`
   (`>= today`, forward-only, as v2_0014 already does) then materialise
   `[today, today+35]` from the slots.
3. A "Rewrite my week" that keeps the same split preserves nothing custom by
   design (the split itself changed); a rewrite that *doesn't* change the split
   keeps the default order. (Reorders live in the slots and are only rewritten
   when the program is rebuilt — acceptable: rebuilding the plan is an explicit,
   heavier action than a day swap.)

### Swap RPC — `swap_scheduled_days(p_user_id, p_from date, p_to date, p_scope text)`

`p_scope ∈ ('week','forever')`, self-auth'd, forward-only (both dates `>= today`).

- **week**: swap `program_day_id` between the `scheduled_workouts` rows on
  `p_from` and `p_to`. This week only; the pattern is untouched.
- **forever**: swap `program_weekday_slots.program_day_id` for
  `isodow(p_from)` and `isodow(p_to)` in the active program, then update every
  future `scheduled_workouts` (`>= today`) on those two weekdays to match the
  new slots. Past untouched.

Undo = the inverse call `swap_scheduled_days(p_to, p_from, scope)`; the client
issues it on "Undo".

`train_screen` is **unchanged** — it already reads the label per date from
`scheduled_workouts`; with one clean row per date the labels are correct.

## Scope boundary

Dragging reorders the split **among existing training days** (a swap between two
training days). Dragging a session onto a **rest** day — which would change
*which* days are training days — stays a Profile "training days" action, out of
this batch. (Matches the user's example: M–S stays M–S, only the labels move.)

## Client

- **Models**: `TrainScreenV2.week[i].label` already carries the tag. Add
  nothing.
- **Week strip** (`train_screen.dart`): each training day's tag becomes a
  `LongPressDraggable`; other days are `DragTarget`s. On drop → **move sheet**
  (design's Now → After the move, buttons *Just this week* / *Every week from
  now* / *Leave it where it was*).
- On confirm: optimistic swap in the local `week` list, call
  `swapScheduledDays(from, to, scope)`, show a toast with **Undo** (inverse
  call + re-fetch). On failure, re-fetch to reconcile.
- **Service**: `swapScheduledDays(from, to, scope)`, `ensureSchedule()`.

## Migration

`v2_0016`: create `program_weekday_slots` + RLS; recreate
`bootstrap_user_program` (slots + 35-day materialise); add `ensure_schedule`
and `swap_scheduled_days`. Backfill slots for any existing active program from
its current `scheduled_workouts` so live accounts keep working.

## Risks / edge cases

- **Existing accounts** have no slots. The migration backfills from their
  current schedule (derive weekday→program_day from the nearest future rows);
  `ensure_schedule` then extends the horizon.
- **Multiple rows per date**: today's `unique (user_id, scheduled_for,
  program_day_id)` permits two rows on one date. `ensure_schedule` and swaps
  keep one row per date; v2_0014 already clears the stale duplicates.
- **DST / week anchoring**: all date math is on `date`, ISO weekday — no tz
  drift.
