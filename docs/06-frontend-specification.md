# LOAD — Frontend Specification Document

**Status:** Draft v1 — fourth of five planning documents, written before the
next design pass. This is the brief a design session needs: what's already
built and validated (keep, unless there's a real reason to change it), what's
a fixed system token (colors, type, motion vocabulary), and what's explicitly
open for reinterpretation. Grounded in the real Flutter implementation on
`main` (`lib/theme/`, `lib/widgets/app_widgets.dart`, `lib/screens/`), not a
mockup.

---

## 1. How to use this document

Three tiers, marked per section:

- **🔒 Locked.** Validated through real use (per the PRD's product
  principles, §5). Don't relitigate without a stated reason — a design pass
  can restyle within these constraints but shouldn't discard them silently.
- **🎨 Open.** Real gaps or known-rough edges worth a genuine design pass.
- **📋 Reference.** Descriptive — what exists today, given as ground truth
  so a design session isn't reverse-engineering the running app from
  scratch.

## 2. Design system

### 2.1 Palette 🔒

Warm, coach-like, explicitly **not** the orange-and-cream generic-AI look
(a deliberate, stated rejection — see PRD principle 7). Source values are
oklch; hex below is the converted sRGB the app actually ships.

| Token | Hex | Use |
|---|---|---|
| `background` | `#FCF3EE` | Page background — warm cream |
| `surface` | `#FFFFFF` | Cards |
| `inputFill` | `#F8ECE6` | Inputs, inset wells, slim rows (protein, nudges) |
| `divider` | `#F4E4DD` | Hairlines inside white cards |
| `peach` | `#FBE2D9` | Nudge/welcome-back banners |
| `chipFill` | `#FEE5DC` | Small pill backgrounds, cue-number dots |
| `accent` | `#B94642` | Primary — warm brick red. CTAs, progress, brand |
| `onAccent` | `#FFFFFF` | Text/icons on accent |
| `textPrimary` | `#2D211E` | Headings |
| `textBody` | `#322523` | Body copy on cards |
| `textMuted` | `#443734` | Slightly lighter body |
| `textSecondary` | `#7C6E69` | Labels, captions |
| `textFaint` | `#9A8C85` | Disabled/faint |
| `inactive` | `#8B7D77` | Inactive tab glyphs |
| `warning` | `#AD5600` | Injury-conflict warnings |
| `note` | `#8C541F` | Coach note about a prior session, PR-highlight cards |
| `positive` / `positiveSoft` | `#006925` / `#E3F0E4` | Progress, PRs, "same or better than last time" |
| `error` | `#B3261E` | Form validation |
| `track` | `#EADAD3` | Progress-bar/ring background track |

No dark mode exists or is planned for v1 (native mobile only, single user,
not a stated need — flag as 🎨 open if that changes).

### 2.2 Typography 🔒

Single family: **Nunito**, weights 400/600/700/800/900, bundled as static
TTFs (`assets/fonts/`), not fetched at runtime.

| Role | Weight | Size | Use |
|---|---|---|---|
| `headlineMedium` | 800 | 24 | Screen titles ("Push Day", "Progress") |
| `titleLarge` | 800 | 22 | Onboarding step headings, sheet titles |
| `titleMedium` | 700 | 13.5 | Card titles, exercise names |
| `bodyLarge` | 600 | 13 | Primary body |
| `bodyMedium` | 600 | 12.5 | Secondary body |
| `bodySmall` | 600 | 11 | Captions |
| `labelSmall` | 700 | 11 | Small accent eyebrows |

Numeric displays (weight/rep steppers, count-up stats) run heavier
(800–900) and larger than surrounding body text — numbers should read as
the point of the screen, not incidental.

### 2.3 Shape & spacing 🔒

| Token | Value | Use |
|---|---|---|
| `AppRadii.card` | 16 | Standard cards |
| `AppRadii.button` | 24 | Primary buttons |
| `AppRadii.smallButton` | 14 | Compact buttons (inline "Log") |
| `AppRadii.input` | 10 | Text field borders |
| `AppRadii.pill` | 20 | Chips, mini-pills |
| Hero cards | 26 | Larger than standard — Today hero, celebration stat tiles, bottom sheets' top corners |

Screen padding is consistently 20px horizontal. Card internal padding
defaults to 15/13 (h/v), with looser 16–20 for hero-weight cards.

### 2.4 Elevation 🔒

No Material elevation shadows anywhere — every "raised" surface is a flat
color-fill against the cream background, with at most a soft, wide,
low-opacity drop shadow on hero-weight cards only (`black @ 7% alpha, 26
blur, (0, 10) offset`). Standard cards have no shadow at all; hierarchy comes
from color-fill (white on cream) and radius, not elevation.

### 2.5 Iconography 📋

Mostly Material rounded icons (`_rounded` suffix family) at small sizes
(15–23px), always paired with the accent or a text color, never black.
Exercise/session imagery is real photography/animated WebP (see §2.6), not
icons — icons are for UI chrome only (nav, steppers, affordances), never
standing in for content.

### 2.6 Exercise media 🔒

Every catalog exercise has a real demo asset (static WebP or animated WebP)
in Supabase Storage, resolved through `exercises.demo_path` →
`storage.from('exercise-media').getPublicUrl(path)`. `ExerciseDemoMedia`
(16:10, rounded 16) is the one shared widget for this and must stay the one
shared widget — never duplicate the placeholder/loading/error states in a
second widget. Placeholder (a "coming soon" icon+label) is the graceful
fallback for a null/failed URL, never a broken-image icon.

### 2.7 Motion vocabulary 🔒

Named patterns, reused rather than invented per screen:

| Pattern | Where used | Timing/curve |
|---|---|---|
| Exercise slide-in | Session flow, advancing between exercises | 240ms, fade + slide from +5% offset, `easeOutCubic` |
| Sheet-up | Log sheet, protein sheet, any bottom sheet | Flutter's native modal-bottom-sheet transition |
| Check pop | Post-log confirmation overlay | 320ms scale+fade, `easeOutBack`, accent-filled circle |
| Ring draw | Celebration ring, Today hero progress ring | Swept arc via `CustomPainter`, not a static asset |
| Check draw | Celebration checkmark | `PathMetric` partial-path extraction — genuinely traces, not a fade-in |
| Count-up | Celebration stat tiles (volume/sets/minutes) | 0→target over ~800ms of the celebration window, `easeOut` |
| Confetti | Celebration screen entry only | 14 pieces, staggered delay/duration, one-shot (not looped) |
| Non-blocking rest bar | Session flow, between exercises | Persistent inline bar, never a blocking modal/countdown screen |
| Splash mark | App boot | Barbell bends into shape (bezier control-point animates via `elasticOut`) → wordmark drops → dot pops → tagline fades, ~2.6s, one-shot |

Rule underlying all of these: **motion earns its place by communicating a
real state change** (something logged, something completed, time passing).
No decorative/idle animation, no motion competing with the single-exercise
focus principle mid-session.

## 3. Navigation / information architecture 🔒

```
Splash (once, on cold boot)
  → AuthGate
      ├─ signed out → Auth (sign in / sign up)
      └─ signed in
          ├─ profile incomplete → Onboarding (7 steps + review)
          └─ profile complete   → App Shell (bottom tab bar)
                                    ├─ Today
                                    ├─ Progress
                                    ├─ Coach (chat)
                                    └─ Profile (Settings)
```

Two navigation registers, deliberately different:

- **Tab bar surfaces** (Today/Progress/Coach/Profile) — persistent chrome,
  switching is instant, state persists via `IndexedStack` (no rebuild/reload
  on tab switch).
- **Full-screen takeovers**, pushed as real routes, no tab bar visible:
  Session Flow (`fullscreenDialog: true`, intercepts system back via
  `PopScope` → exit-confirm dialog if anything was logged) and Celebration
  (`pushReplacement`, no back at all — finishing a session is a one-way
  door into reflection, not a screen you bounce back out of accidentally).
  Guide screen is a normal push (back button, no confirm needed — nothing
  destructive there).

This split exists because Session Flow's whole premise (PRD principle 2:
"the session view shows one exercise and nothing else") is violated the
moment tab-bar chrome is visible during a set. Any future screen that wants
the same focused-task treatment should use the same
full-screen-takeover-with-confirm-exit pattern, not a modal sheet.

## 4. Screen inventory

### 4.1 Splash 🔒 📋

One-shot boot animation (§2.7), then hands off to `AuthGate`. No
interaction, no skip button (2.6s is short enough not to need one — revisit
if that changes).

### 4.2 Auth 📋

Email/password (with confirm-password on signup) + Google Sign-In. No
forgot-password (PRD §8, deliberate). Single-user product; this screen gets
the least design attention of any surface — functional, on-brand, not a
priority for the next design pass.

### 4.3 Onboarding — 7-step intake 🔒 (flow) / 🎨 (visual polish)

One decision per screen (goal → units → current weight → experience →
environment → injuries → split preference), review step before saving. This
structure — "the coach asks, not a form dump" — is a locked product
decision (PRD §5, principle-adjacent). Visual treatment of individual steps
is open for a design pass; the one-question-per-screen *shape* is not.

### 4.4 Today — the most-used screen 🔒 (structure) / 🎨 (polish opportunities)

State machine, not a single layout:

- **No plan** — building/incomplete-profile state, centered message.
- **Active** — hero card (today's exercises, progress ring once anything's
  logged, CTA), weekly weigh-in nudge (conditional, ≥5 days since last),
  protein slim row (tap → bottom sheet), missed-session nudge (conditional).
- **Complete** — hero card becomes a result summary (icon, stats, then a
  per-exercise breakdown with a delta vs. last time — "+15 lb" / "Same as
  last" / "2 sets short" / "First time logged"), an "Up next" card
  (collapsible, real thumbnails of the following scheduled session,
  tap-through to Guide).

🎨 open: the "Up next" thumbnail card is new and unpolished relative to the
rest of the screen — worth a real design pass rather than treating the
current implementation as final. Also open: whether/how a genuine rest-day
state should render (today's backend always resolves *some* plan; a true
rest-day concept doesn't exist yet — see Feature Ticket List).

### 4.5 Session Flow — full-screen, no chrome 🔒 (mechanics) / 🎨 (visual detail)

Locked mechanics (validated, PRD principle 2 + 5):

- Close (✕) + elapsed timer header, segmented per-exercise progress bar.
- One exercise per screen: name, prescription, injury banner (+ swap if
  available), real demo media, numbered form cues.
- Log sheet (bottom sheet): simple mode (one weight/reps/sets, pre-filled
  from last time) as the default fast path; per-set mode as the escape
  hatch, never the default.
- Non-blocking rest bar (inline, skippable, auto-advances at zero) — never
  a blocking countdown screen.
- Primary CTA does triple duty by state: "Done — log it" → "Next exercise"
  → "Finish session", auto-advancing/auto-finishing rather than requiring a
  confirmation tap for work already done.
- Exit-confirm only fires if something was actually logged this session.

🎨 open: the log-sheet stepper visual treatment (small circular +/−
buttons) is functional but plain; the injury-swap banner styling is
minimal. Both are reasonable design-pass targets that won't touch the
locked mechanics above.

### 4.6 Celebration 🔒 (ordering) / 🎨 (visual richness)

Locked ordering (PRD principle 3, reward before ask): drawn ring+check →
headline → count-up stat tiles (volume/sets/minutes) → comparison vs. last
time → PR highlight cards (if any) → *then* RPE chips → pain chips →
optional note → Done. The session isn't marked complete server-side until
Done is tapped — reflection is real, not decorative, but it comes after the
reward, never before.

🎨 open: PR highlight card styling, comparison-banner visual weight —
reasonable to push further than the current functional-but-plain
treatment.

### 4.7 Guide 📋

Static reference: demo media, prescription, numbered form cues, "if
something hurts" banner. Reached from the Today hero card's per-exercise
info icon or from "Up next" thumbnails — not from inside an active session
(the session flow shows this content inline already, per §4.5).

### 4.8 Progress 📋

Consistency grid, bodyweight trend, per-exercise strength trend, session
history. Straightforward charts-and-list screen; lowest design priority of
the tab-bar surfaces since it's checked, not lived in daily.

### 4.9 Coach (Chat) 📋

Message list + input, natural-language logging via propose→confirm cards
(server round-trip, never writes directly — Security & Access doc). Secondary
surface by design (PRD principle throughout doc 01/03) — should never visually
compete with Today for primary real estate or attention.

### 4.10 Profile / Settings 📋

Permanent weigh-in card (moved here from Today, per the weekly-cadence
principle), editable onboarding fields, units toggle, sign out. No
"preview/dev tool" surfaces (rest-day toggle, session-reset button) —
explicitly never shipped as real settings, even though an earlier design
mock included them for its own testing purposes.

## 5. Component library 📋 (reference — extend, don't duplicate)

Shared, reused across screens — a design pass should style/extend these,
not invent parallel one-off versions:

`AppCard`, `SelectableRow`, `ChoiceChipButton`, `MiniPill`, `SectionLabel`,
`SoftBanner`, `ScreenHeader`, `EmptyHint`, `ExerciseDemoMedia`.

Screen-local widgets (log sheet steppers, celebration stat tiles, hero
card, confetti pieces) currently live private to their screen file. If a
design pass wants one of these reused elsewhere, promote it to
`lib/widgets/` rather than copy-pasting — this has already happened once
(`ExerciseDemoMedia` was extracted specifically to avoid two divergent
placeholder implementations).

## 6. Content & voice 🔒

- Warm, direct, second-person, no exclamation-point enthusiasm. "Nice
  work — session's in the books," not "AMAZING JOB!! 🔥"
- Numbers over adjectives wherever possible — "+15 lb" beats "You crushed
  it."
- Coach copy is specific to the lifter's real data or it doesn't ship — no
  generic filler text standing in for a real number, even in an empty/
  loading state (use an honest "nothing yet" message instead).
- No medical claims. Pain-related copy always routes toward "swap it" or
  "get it looked at," never toward diagnosis.

## 7. Accessibility 🎨 — real gap, not yet addressed

Not currently a design or implementation focus; flagged here as genuinely
open rather than silently skipped:

- Dynamic type / text scaling hasn't been tested against the fixed-size
  numeric displays (steppers, count-up stats) — likely to clip or overlap
  at larger accessibility text sizes.
- No screen-reader labeling pass has been done (semantic labels on
  icon-only tap targets, custom-painted rings/checks with no text
  fallback).
- Color contrast has not been formally checked against WCAG AA, though the
  palette's text-on-background pairings are generally high-contrast by
  construction.

Recommendation: treat as a real ticket in the Feature Ticket List, not a
"someday" — v1's single user doesn't need it urgently, but it's cheap to
fix early and expensive to retrofit once the component count grows further.

## 8. Platform & device 🔒

Native mobile only (Flutter, iOS + Android), no responsive/tablet layout
(PRD §9). Reference device for the current build has been an iPhone
simulator; Android has not had an equivalent visual QA pass — 🎨 open,
worth a real device/emulator pass before considering the UI "done" on
Android specifically, not just build-succeeds.

## 9. Open questions for the design pass

- Today screen's "Up next" card and the log-sheet stepper visuals are the
  two most obviously unfinished-looking surfaces in the current build —
  good first targets.
- Whether a true rest-day state is worth designing for now, or deferred
  until the backend actually models rest days (currently `today_plan()`
  always resolves some session).
- Whether dark mode is worth doing now or stays out of scope indefinitely
  (currently: no plan, no ticket).
- Android-specific visual QA has not happened; unclear yet whether that
  surfaces real design gaps or is a non-issue.

---

*Next: `07-feature-ticket-list.md`, then back to `04-technical-architecture.md`
and `05-security-and-access.md`.*
