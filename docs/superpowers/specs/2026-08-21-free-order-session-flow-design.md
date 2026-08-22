# Free-order session execution — design (#7)

From `LOAD Session Flow v2.dc.html`: "No lift is *next*. The rail is a live map
of the session, the board reorders it, a half-finished lift stays half-finished
until you come back, and the rest timer keeps running while you go do something
else."

## What changes vs today

Today `SessionController` is linear: a single `idx`, `advance()` steps
`idx → idx+1 → finish`, and the rail is a progress bar. Sets are already stored
per-exercise (`_sets[i]`), so half-finished lifts already keep their sets — the
gap is purely **navigation**: you can only go forward, one lift at a time.

Free-order keeps the per-exercise storage and the whole lift/set/effort/rest
engine; it replaces *how you move between lifts*.

## Model

- **No linear advance.** Add `goTo(i)` — jump to any lift. `advance()` becomes
  "go to the next lift that still needs sets, else review" (a convenience, not
  the only path).
- **Rail = live map.** Each lift shows a state: `untouched` / `in progress`
  (some sets, below target) / `done` (target met) / `deferred` (saved for the
  end). Tapping a rail item is `goTo`. No "next" arrow implied.
- **Board — "Today's lifts"** (bottom sheet): the lifts with drag-to-reorder
  and tap-to-jump. Reorder changes the in-session order (`_order` index list);
  half-finished lifts keep their sets. Footer: **Make it the plan** (persist the
  new order to `program_day_exercises.ordinal`) or **Just today** (session-only).
- **Rest timer is session-global.** It already lives on the controller; decouple
  it from the current lift so "Do something else while you rest" works — start a
  rest, `goTo` another lift, log there, the rest keeps counting and a compact
  rest chip stays visible. On expiry it nudges regardless of which lift is open.
- **Deferred ("save for the end").** Already modeled (`EntryModeV2.deferred`);
  surface it as an explicit rail state and collect those lifts on the review
  screen "the bits you saved for later", in the order actually trained.
- **Finish / review** stays: review lists lifts in trained order, auto-fills
  untouched-deferred at plan, then done.

## Order persistence

- **Just today**: reorder the in-session `_order` only. Nothing written until
  the sets are (each set already writes with its real exercise).
- **Make it the plan**: an RPC `reorder_program_day(program_day_id, exercise_ids
  in new order)` rewrites `program_day_exercises.ordinal`. Self-auth'd. Future
  sessions of that day then present the new order. (Small migration `v2_0017`.)

## Client surface

- `SessionController`: `goTo(i)`, `List<int> _order` (display order over
  exercises), `reorder(from,to)`, per-lift `LiftState state(i)`, rest decoupled
  from `idx`. Persist path calls `reorderProgramDay`.
- `session_flow_screen.dart`: rail becomes tappable state chips; add the
  "Today's lifts" board sheet (reorderable list, jump, Make-it-the-plan/Just-
  today); a persistent rest chip when resting-while-elsewhere; the review's
  "saved for later" section. The existing lift/set/effort/rest widgets are
  reused as-is.

## Scope / risk

- Biggest single change of the batch — the session flow is the app's core loop,
  so this warrants building behind careful device testing (start a lift, jump
  away mid-set, rest running, come back, reorder, defer, finish).
- No change to how sets/effort/rir are written — only navigation and order.
- `reorder_program_day` is the only new DB object.

## Open questions for you

1. **Reorder scope default**: when someone reorders mid-session, is the default
   button *Just today* (safer) with *Make it the plan* secondary — or the
   reverse?
2. **Swap-in a different exercise** and **"What's going on?" situation** appear
   in the same design. Include them in this batch, or ship free-order +
   reorder first and add swap-in/situations as a follow-up? (They're each
   sizable on their own.)
