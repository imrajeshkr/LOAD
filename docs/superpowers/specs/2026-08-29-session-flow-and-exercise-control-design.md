# Session flow and exercise control — design

**Status:** approved in chat 2026-08-29, not yet implemented.

Nine annotated items from a real session on the simulator. They decompose into
two projects that ship independently.

| | |
|---|---|
| **A — Session flow** | The lift screen behaves like a form to fill in, not a workout to do. Items 1–7. No schema. |
| **B — Exercise control** | The plan is fixed once generated. Items 8–9. New RLS, new UI, uses `exercises.owner_id` for the first time. |

A is where the daily friction is, so A goes first.

---

## 1. What is wrong today

The lift screen has a **start gate**. Set rows render blank and inert until you
tap "Start this lift", and even then only the *next* row is editable — future
rows are `surfaceSunken` with dead steppers. So the first thing a lifter does
on every single exercise is tap a button that does nothing except unlock the
screen.

Everything else on the list follows from that one decision:

- The numbers are not there, so you cannot glance and go.
- The circles look like decoration rather than controls.
- The primary button says "Start this lift" because starting is a real step.
- Cues open by default (`cuesOpen = true`, and `= _sets[idx].isEmpty` on jump),
  pushing the set table below the fold on the one screen where the set table is
  the entire point.

---

## 2. Project A — remove the start gate

### 2.1 The lift is live on arrival

Items 2, 3 and 4 are a single change, not three fixes.

- Every set row renders **prefilled** from the progression prefill
  (`c.staged()`), which already computes the right weight and reps.
- Every row's steppers are **live**, not just the next one. A lifter who knows
  set 3 will be lighter can say so before starting.
- The circle on each row **is the log control**. Tap it → that set is written,
  the rest timer starts.
- The primary button becomes **Done**, and finishes the lift.

**Done is disabled until at least one set is logged.** Zero sets is not
"done", it is "skipped", and there is already an action for that. Disabling it
also removes the ambiguity of a button that means two different things.

**Every logged set stays editable and undoable in place.** Removing the gate
means a mis-tap writes a set, so the same circle un-logs it. `adjustSet()`
already edits a completed set; undo is the missing half.

### 2.2 Cues hidden by default (item 1)

`cuesOpen = false` on land and on every `jump()`. The "How to" toggle stays
exactly where it is.

**One exception:** cues open automatically the first time a lifter ever
performs a given exercise — no completed sets for it in their history — and
never again. Hiding form cues from someone who has never squatted is not
decluttering, it is withholding. Costs one history check.

### 2.3 Skip and "Log at the end" stop being twins (item 5)

They currently render as two identical secondary buttons, which is why they
feel wrong. They are different intents:

| Action | Means | Frequency |
|---|---|---|
| Do it later | The rack is busy, come back to it | common mid-session |
| Skip | Not doing this today at all | rare, and final |

Neither should compete with the primary action. New bottom bar:

```
┌─────────────────────────────────┐
│            Done                 │   full width, primary
└─────────────────────────────────┘
        Do it later  ·  Skip          one line, text links, subordinate
```

Both stay **visible**. "Do it later" is the busy-rack case and is needed at the
moment of frustration; burying it in an overflow menu means nobody finds it.

### 2.4 The ribbon scrolls and follows you (item 6)

`_Rail` is a `Row` of `Expanded` children, so exercises are squeezed to fit and
names truncate (`STANDING DUMBBE…` with only four lifts). Replace with a
horizontally scrollable list, each item sized to its content, driven by a
`ScrollController` that animates the active item into view on every `jump()`.

Progressing through the session therefore scrolls the ribbon right-to-left on
its own, and lifts off-screen become reachable.

### 2.5 Swipe between exercises, not tap zones (item 7)

**Decision: horizontal swipe with animation, both directions**, plus tapping
any ribbon item to jump directly.

Instagram-style edge-tap zones were considered and rejected. That screen is
dense with tap targets — a stepper on each side of every set row, a log circle
on each row, a cues toggle. An edge tap beside a weight stepper misfires, and
the failure is expensive: it either changes a weight or jumps you off a lift
mid-set. Swipe has no such collision, and the ribbon already provides direct
random access.

---

## 3. Project B — exercise control

### 3.1 Replace until touched (item 8)

Rule, as stated: an exercise can be replaced until **that exercise** has a
logged set — not until the session starts.

This is stricter and better than what shipped in Plan 05, which disabled
replacement for the entire session on the reasoning that swapping a lift with
logged sets would orphan them. That reasoning only applies to the lift you have
actually touched.

Reachable from **both** the Train tab (pre-session) and mid-session.

**Affordance decision: a visible control, not a swipe.** Slide-to-reveal on the
exercise chip was considered and rejected: it is undiscoverable, and this
repository's own convention (`CLAUDE.md`) is that every tappable goes through
`Pressable` precisely so affordances are visible and feel pressed. A gesture
nobody finds is not a feature.

The picker gains **filter chips** — Push / Pull / Legs / Core, and target
muscle — above the existing search field.

### 3.2 Adding exercises (item 9)

"**+ Add exercise**" at the end of the day's list on the Train tab, and in the
in-session board. Opens the same picker, with "**Can't find it? Create one**"
at the bottom.

The generator's 4–6 slot cap is a *generation* rule, not a limit on the lifter.
Manual additions append beyond it; nothing in the generator changes.

### 3.3 Custom exercises are private

**Decided:** a custom exercise belongs to its author. `owner_id = auth.uid()`,
`is_core = false`.

That combination means the generator ignores it for free — `bootstrap_user_program`
already filters `owner_id is null and e.is_core`, so no generator change is
needed and no one else can ever be prescribed someone's homemade lift.

Rejected: publishing custom exercises to the shared catalogue. It fills the
catalogue fastest and inherits everything that comes with it — duplicate
"Bench Press" / "bench press" / "BB Bench", wrong muscle tags, and unreviewed
uploaded images on a surface we are responsible for. A good custom exercise can
still be promoted later by flipping `owner_id` to NULL; the schema already
supports exactly that, so nothing is lost by starting private.

### 3.4 Images, contributed one lifter at a time

Creating an exercise offers an **optional** photo. In-session, a lift with no
illustration shows **"Add a photo"** in place of the placeholder icon.

This is the quiet answer to the licence problem in `docs/PENDING.md`: 494
catalogue exercises have no illustration because the dataset's image rights
were never clarified. Images a lifter takes themselves have no such question,
and they accumulate against the exercises that lifter actually uses.

Stored in the existing public `exercise-media` bucket under the owner's folder,
mirroring the `avatars` convention.

### 3.5 Scope prompt

**Decided:** replace and add both ask once — **"Just today"** or **"Every
week"**.

- *Just today* touches only this session.
- *Every week* writes to the plan and survives regeneration through the
  existing `exercise_swaps` table (Plan 05, `v2_0034`/`v2_0035`).

Rejected: always-permanent, because "the squat rack was busy so I did leg press
once" would silently become the programme. Rejected: always-today, because
someone who genuinely dislikes an exercise would have to replace it every week,
and the standing-swap machinery already built would go unused.

---

## 4. Data model

**No new tables.** Two changes:

### 4.1 RLS on the join tables — the one real blocker

`exercises` is already correct and needs nothing:

```
exercises_read       SELECT  owner_id IS NULL OR owner_id = auth.uid()
exercises_write_own  ALL     owner_id = auth.uid()
```

But `exercise_muscles`, `exercise_equipment` and `exercise_joints` each carry
**only** a read policy (`using = true`, no INSERT). So today a lifter could
create an exercise row and then fail to attach its muscle or its equipment —
leaving a nameless orphan the picker cannot filter and the injury check cannot
read.

`exercise_cues` stays read-only. The create form does not collect coaching
cues, so granting write access to a table nothing writes would be permission
we do not need.

Needs a write policy on each, scoped to exercises the caller owns:

```sql
exists (select 1 from exercises e
         where e.id = exercise_id and e.owner_id = auth.uid())
```

Scoping to `owner_id = auth.uid()` and not merely "authenticated" matters: it
must remain impossible to attach a muscle to a *catalogue* exercise and change
what every other lifter is prescribed.

### 4.2 Custom exercises need joint data too

`v2_0033` derived joint stress for all 530 catalogue exercises precisely so the
injury filter could see them. A user-created exercise starts with none, which
makes it invisible to that filter rather than safe — the exact failure
`v2_0033` was written to fix.

Since we cannot ask a lifter to rate joint stress, a custom exercise inherits
the derivation rules by its declared pattern and primary muscle, applied at
creation. Coarser than the catalogue, honest, and never zero.

---

## 5. Risks

- **A mis-tap now writes a set.** Mitigated by making the log circle a toggle
  (§2.1), which is required, not optional.
- **Swipe versus vertical scroll.** The lift body scrolls vertically inside a
  horizontally-swiped pager. Standard, but needs testing on a real device where
  a diagonal thumb drag is common.
- **Custom exercises never get progression history.** They work with the
  existing prefill (catalogue default, then history), but they have no
  `default_start_kg`, so the first session starts from whatever the lifter
  types. Acceptable; worth confirming it does not render as `0 kg`.

## 6. Not in scope

- Publishing custom exercises to the shared catalogue (§3.3).
- A moderation or review queue — unnecessary while custom exercises are private.
- Replacing the 494 missing catalogue illustrations. §3.4 chips away at it for
  exercises a lifter actually uses; it does not solve it.
