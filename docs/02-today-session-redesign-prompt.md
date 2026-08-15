# Design + build prompt — Today screen and the session flow

> Paste this whole file into Claude Code. It assumes PR #4 (`today_plan` client
> wiring) is merged, so the data described here is already available.

---

## 1. What exists, and what's wrong with it

The Today screen works and reads real data, but it reads like a **utility app**:
a stack of identical white cards, every value the same visual weight, no motion,
no hierarchy, no sense of momentum. It answers "what are the numbers" when it
should answer "what do I do next".

Three specific failures to fix:

1. **The session is not a flow.** Tapping an exercise opens a logging form with
   steppers, a set list, an edit affordance and navigation buttons all at once.
   During a set, the lifter has to read a form. They shouldn't have to read
   anything.
2. **Guidance is buried.** "How do I do this" lives behind a `Guide` pill on a
   separate route. It should be the *main content* of the screen while you're
   doing the exercise.
3. **Daily noise for a weekly action.** The weigh-in card sits on Today every
   single day. People weigh in about once a week. It's clutter 6 days out of 7.

---

## 2. The principle

> **The lifter should never have to think about the app.**
> Pre-gym: one glance tells them what today is.
> In-gym: one thumb, one tap per step, no reading.
> Post-gym: a moment that feels earned.

Every decision below serves that. If something adds a decision the lifter didn't
ask for, cut it.

---

## 3. Screen 1 — Today (pre-session)

The landing screen. Its only job is: *show me what today is, and let me start.*

### Layout, top to bottom

**Header**
- Eyebrow: the date, quiet.
- Title: the program day label (`Push Day`) — large, confident, the biggest
  thing on screen.
- Under it: one line of momentum — `2-day streak · 3rd session this week`.
  Only render if there's something real to say; no zero-states here.

**The session card** — the hero. This is one large card, not a list.
- Shows the day's exercises as a compact ordered list *inside* one card:
  name + prescription only (`Bench Press · 4 × 8–10`). No weights, no status
  columns, no per-row chrome. It's a preview, not a table.
- A progress ring or bar showing `n of m` complete, if a session is underway.
- The primary CTA lives inside this card at the bottom, full width:
  - No session yet → **Start Push Day**
  - Session partially done → **Continue · 2 of 4 left**
  - All done → the card switches to its completed state (see below)
- Tapping anywhere on the card = the CTA. One target, hard to miss.

**Rest day variant**
When there's no session scheduled, the hero card becomes a calm rest-day card:
what's next and when (`Next up: Pull Day, tomorrow`), plus a low-key
`Log something anyway` secondary action for off-plan training. No empty
exercise list, no disabled button.

**Completed-today variant**
Once the session is finished, the hero card collapses into a summary state:
the day label, a check, and the headline numbers (`15 sets · 3,285 kg`).
Tapping it reopens the post-session summary (Screen 4) read-only.

**Below the hero — the quiet zone**
Everything else is secondary and should look it. Smaller, lighter, no accent
colour competing with the CTA.
- **Protein**: a slim row with a progress bar — `112 / 145 g`. Tap opens a
  small input sheet. This one stays daily; it's genuinely a daily thing.
- **Weigh-in: remove from Today.** Replace with a *conditional* prompt that
  only appears when the last weigh-in is 5+ days old, phrased as a nudge
  (`It's been a week — quick weigh-in?`) and dismissible for the day. The
  always-available path to log weight moves to the Profile tab.

### What to delete from the current Today screen
- The per-exercise weight column and `Done` status text (the session card
  preview doesn't need them).
- The permanent weigh-in card.
- The `Guide` pill on each row — guidance belongs in the session flow now, not
  as a per-row affordance on the landing screen.

---

## 4. Screen 2 — The session flow (the main event)

Entered from **Start**. This is a **focused, full-screen flow with no bottom
nav** — the lifter is in the gym, not browsing the app. Exiting requires an
explicit close (with a confirm if sets are logged).

### Structure: one exercise at a time

A horizontal pager, one page per exercise, driven by the flow — not free
swiping between arbitrary exercises. Top of screen carries a **thin segmented
progress indicator** (one segment per exercise, filled as each completes) plus
elapsed time. That's the only persistent chrome.

### 4a. The exercise page — guidance is the content

This is the biggest change. While the lifter is on an exercise, the screen is
mostly **how to do it**:

- **Exercise name**, large.
- **The prescription, stated once, in plain language**: `4 sets · 8–10 reps`
  and, if it has a load, `Last time: 25 kg`. One line. Not a form.
- **The demo** — the looping clip slot, given real space (16:10, full width).
  Until real media exists, render the existing styled placeholder; do not
  shrink the slot to compensate.
- **Form cues** — numbered, generous line height, easy to read at arm's length
  with a barbell in the way. These are currently good; keep the numbered-circle
  treatment.
- **Injury flag**, if the exercise conflicts with a stated constraint — a warm
  caution banner with a **Swap** action inline.

**No steppers. No set list. No weight input.** Not on this page.

**One primary button at the bottom: `Done — log it`.**

### 4b. The log sheet — appears only when the exercise is finished

Tapping `Done — log it` raises a **bottom sheet** (not a new route — the
exercise stays visible behind it, so context is never lost).

The sheet's default state is the whole point:

- It arrives **pre-filled** with the prescription and last session's load —
  e.g. `3 sets · 25 kg · 10 reps`, shown as one confident line, not three
  inputs.
- Two large steppers: **weight** and **reps** — these apply to *all* sets.
- A set-count control (`3 sets`), defaulted to the prescribed number.
- Primary: **Log 3 sets**. One tap. Done.
- Secondary, small, quiet: **Sets weren't all the same** → expands to the
  per-set rows (the existing per-set editing UI, reused), for people who ramp
  or drop weight across sets.

For **bodyweight exercises**, the weight stepper is absent entirely — reps and
set count only.

Rationale to preserve: three identical sets currently cost three logging
interactions. This makes it one, while keeping per-set accuracy available for
those who need it. That is the "click click click" requirement.

### 4c. After logging — rest, then advance

On confirm:
1. The sheet dismisses.
2. A brief **set-logged confirmation** — the segment for this exercise fills,
   a check animates in. ~600 ms, non-blocking.
3. A **rest timer** appears as a slim persistent bar at the bottom, counting
   down from the prescription's `rest_seconds`. It shows remaining time and a
   `Skip` action. It must not block the screen.
4. The pager **auto-advances to the next exercise** once the timer completes,
   or immediately if the lifter taps `Next`. Advancing should feel like the
   next exercise slides in, not a page reload.

On the **last exercise**, the button reads `Finish session` and goes to
Screen 4 instead of advancing.

---

## 5. Screen 3 — Mid-session exit and resume

If the lifter leaves mid-session (backgrounds the app, closes the flow):
- Today's hero card shows `Continue · 2 of 4 left`.
- Re-entering the flow resumes at the **first incomplete exercise**, not at the
  start.
- Already-logged exercises show as complete in the segmented indicator, and
  their pages show what was logged (`3 × 25 kg × 10 ✓`) instead of the
  `Done — log it` button, with an `Edit` affordance.

---

## 6. Screen 4 — Post-session (the payoff)

This screen has one job: **make the work feel worth it.** It is the only place
in the app where celebration is appropriate — spend the delight budget here.

### Sequence on arrival
1. **Celebration moment** — a short, tasteful animation. A ring completing, a
   burst of soft confetti in the warm palette, or a check that draws itself.
   ~1.2 s, plays once, never blocks. It should read as *warm*, not arcade.
   Avoid: bouncing, loud sound, anything that repeats.
2. **Headline**: the day label + a human sentence — `Push Day, done.`
3. **The numbers, animated counting up** from zero over ~800 ms:
   - Total volume (`3,285 kg`)
   - Sets completed (`15 of 15`)
   - Duration (`52 min`)
4. **The comparison line** — the most important thing here, from
   `session_last`: `+155 kg vs your last Push Day`. Give it prominence and
   positive colour when up. If there's no prior session for this day, say so
   warmly (`First Push Day logged — this is your baseline now.`) rather than
   hiding the row.
5. **Highlights** — any PRs, as cards. Reuse the existing trophy treatment.
6. **How did it feel?** — the RPE chips. Keep, but move *below* the celebration
   so the reward comes before the ask.
7. **Anything hurt?** — the pain chips, unchanged in behaviour.
8. **Notes** — optional, collapsed by default behind `Add a note`.
9. **Done** — returns to Today, which now shows the completed hero card.

Nothing on this screen should be a required input. The lifter can hit `Done`
immediately and lose nothing.

---

## 7. Visual system — what to add

The current palette and type are right; the *application* of them is flat.
Keep the tokens in `app_colors.dart` / `app_theme.dart`. Add:

**Depth**
- The active/hero card gets a soft shadow and slightly larger radius than
  secondary cards. Right now everything is elevation 0 and reads as one plane.
- Secondary rows (protein, nudges) should sit *flatter* than the hero — tint
  rather than white, or no card at all.

**Hierarchy through scale, not colour**
- Numbers that matter (volume, weight, the count-up stats) should be large and
  set in the extra-bold weight already bundled.
- Labels shrink and lighten. Currently labels and values are too close in
  weight, which is what makes it read like a spreadsheet.

**Progress made visible**
- Segmented bar in the session flow.
- A ring on the Today hero card when a session is partway through.
- The protein bar already exists — keep, it's the right idea.

**Motion** (all with a consistent easing — prefer `Curves.easeOutCubic`)
- Page transitions between exercises: slide + subtle fade, ~280 ms.
- Sheet presentation: standard, but ensure the exercise stays visible behind.
- Number count-ups on the summary: ~800 ms.
- Completion check: draw-on, ~400 ms.
- Celebration: ~1.2 s, once.
- Every state change that represents progress should animate. Nothing should
  simply appear.

**Cards and chips**
- Exercise rows inside the hero card: no individual card treatment, just rows
  with generous spacing — the *card* is the session, not each exercise.
- Keep the existing pill/chip components; use them for status, not for actions
  buried in rows.

---

## 8. Hard constraints — do not break these

- **Backend contract is fixed.** Everything needed is already in `today_plan()`:
  prescription, `last`, `today`, `prefill_kg`, `prefill_reps`, `rest_seconds`,
  `load_type`, `joints`, `cues`, `session_now`, `session_last`. Do not add
  migrations for this work. If something seems missing, check the RPC first.
- **`AppState` stays the single source of truth for logged sets** — reading
  from `today_plan`, refetched after every write. Do not reintroduce a local
  set map; that was the bug fixed in PR #4.
- **Weights are kilograms everywhere internally**, converted only at display
  via `UnitSystem`. The new log sheet must respect this.
- **Bodyweight exercises never show a weight number.** Reps only.
- Keep `Nunito`, the warm palette, and the existing radii tokens.
- `flutter analyze` must stay clean.

---

## 9. Acceptance criteria

Test against the seeded account (`rajesh.test4@example.com`).

- [ ] Today shows one hero session card, not a list of four cards.
- [ ] No weigh-in card on Today unless the last weigh-in is 5+ days old.
- [ ] Weight can still be logged from Profile.
- [ ] Starting a session enters a full-screen flow with no bottom nav.
- [ ] The exercise page shows the demo slot and form cues as its main content,
      with no weight/reps inputs visible.
- [ ] `Done — log it` raises a sheet pre-filled from last session's load.
- [ ] Logging three identical sets takes exactly one confirmation tap.
- [ ] "Sets weren't all the same" reveals per-set editing.
- [ ] A bodyweight exercise's log sheet has no weight stepper.
- [ ] Rest timer appears after logging and does not block the screen.
- [ ] The flow auto-advances to the next exercise.
- [ ] Leaving mid-session and returning resumes at the first incomplete
      exercise.
- [ ] Post-session plays a celebration once, counts the numbers up, and shows
      the vs-last-time comparison.
- [ ] Every progress state change is animated, not instant.

---

## 10. Suggested order of work

1. Session flow shell — pager, segmented progress, no-nav full screen.
2. Exercise page — guidance as primary content.
3. Log sheet — pre-filled, one-tap, with the per-set escape hatch.
4. Rest timer + auto-advance + resume.
5. Today hero card and its four states.
6. Move weigh-in; add the conditional nudge.
7. Post-session celebration and count-ups.
8. Depth/hierarchy pass across all of it.

Ship each as its own commit so the visual changes are reviewable separately
from the behavioural ones.
