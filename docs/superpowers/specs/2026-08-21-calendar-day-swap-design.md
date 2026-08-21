# Train-tab calendar day swap — design (#4)

Drag a day's label on the Train-tab week strip onto another day to rearrange the
split, then confirm the scope: this week only, or every week from now.

## Interaction (from `LOAD Train Tab.dc.html`)

- The week strip shows each day: letter, date, mark (done/today/upcoming),
  and its **tag** (PUSH / PULL / LEGS). A `dragHint` invites reordering.
- Drag one day's tag onto another day → a **move sheet**:
  - `moveTitle` + a **Now → After the move** before/after of the two days.
  - Scope buttons: **Just this week**, **Every week from now**, and
    **Leave it where it was** (cancel).
- On confirm: a toast (`event_available` + `moveToastText`) with **Undo**.

Only *training* days carry a draggable tag; dropping onto a rest day moves the
session onto that day (the vacated day becomes rest).

## The two scopes

**Just this week** — the concrete dates. Swap (or move) the `program_day_id`
on the affected `scheduled_workouts` rows for this week only. Future weeks are
untouched. Fully expressible in today's schema.

**Every week from now** — the *pattern* changes going forward. This is the open
design question, because the current model has **no persistent weekday→label
mapping**: `bootstrap_user_program` generates a fixed rotation across the next
14 days (`slot % day_count`) and nothing stores "Wednesday = Legs". So a
persistent reorder has nowhere to live, and there's no rolling generator to
carry a pattern into week 3+.

### Options for "every week from now"

- **A — Rewrite forward rows to the new arrangement (bounded).** Apply the swap
  to every existing future `scheduled_workouts` row (this week's dates onward),
  matching weekday-of-week. Simple, no schema change, but only reaches as far as
  rows already exist (~2 weeks), and a later "Rewrite my week" reverts it since
  the rotation isn't stored. *Honest but shallow.*
- **B — Persist a weekday→program-day map + a rolling scheduler (recommended,
  architectural).** Add a small mapping (weekday → program_day ordinal) that
  `bootstrap_user_program` writes on generation and reads on swap; a scheduler
  (rolling, or extended horizon) lays down future weeks from that map. Swaps
  edit the map; regeneration preserves it. This is the "real" fix and also
  solves the unrelated "calendar runs out after 14 days" gap.
- **C — Defer "every week" (smallest).** Ship **Just this week** now (clean,
  useful, no schema risk); leave "Every week from now" for the scheduling-model
  work in option B, done deliberately later.

## Recommendation

**C now, B soon.** "Just this week" is the common case, is fully supported by
the current schema, and unblocks the drag-drop UX immediately. "Every week from
now" deserves the proper scheduling-model change (B) rather than the shallow
rewrite (A) that a later regeneration would silently undo — and B is a piece of
work worth its own spec because it also fixes the 14-day horizon.

## If C: scope of this batch

- **DB** `move_scheduled_day(p_user_id, from_date, to_date)` RPC: swap the two
  dates' `program_day_id` (or move onto a rest day), self-auth'd like the other
  RPCs. Idempotent, forward-only (rejects past dates).
- **Client** Train week strip: long-press-drag a tag to another day → move sheet
  (before/after, confirm/cancel) → optimistic swap + toast + Undo (Undo calls
  the inverse move).
- No schema change.

## Open question for you

Go with **C** (Just this week now, Every-week as a later scheduling-model piece),
or do you want **B** (build the persistent mapping + rolling scheduler now so
Every-week works immediately)? B is the bigger, more correct build.
