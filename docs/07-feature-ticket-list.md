# LOAD — Feature Ticket List

**Status:** Draft v1 — fifth planning document, but the second written (after
the PRD), per explicit priority: PRD → Frontend Spec → this list matter most
before the next design pass; Technical Architecture and Security & Access
follow after. Every ticket here traces back to a specific PRD section or
Frontend Spec open item — no ticket exists just because it seemed useful in
the moment.

Sizing is rough (S = hours, M = a day-ish, L = multi-day/needs its own
design pass) and assumes the current solo-builder pace, not a team.

---

## A. Design-pass targets (do alongside or right after the next design session)

These are the concrete "🎨 open" items the Frontend Spec called out — the
actual reason this doc exists before design, not after.

**A1. Redesign the "Up next" card** — *L*
The newest surface on Today, currently functional-only. Needs a real design
pass: thumbnail treatment, collapse/expand interaction, how it reads next to
the completed-session breakdown above it.
*Ref: Frontend Spec §4.4, §9.*

**A2. Redesign log-sheet steppers and injury-swap banner** — *M*
Session Flow's weight/reps/sets steppers and the injury-conflict banner are
both functional-but-plain. Should not touch the locked mechanics (simple
mode default, per-set escape hatch, swap-if-available) — visual only.
*Ref: Frontend Spec §4.5.*

**A3. Redesign PR highlight cards and comparison banner** — *M*
Celebration screen's reward moment is the highest-leverage screen in the
app per PRD principle 3 and deserves better visual weight than the current
functional treatment.
*Ref: Frontend Spec §4.6.*

**A4. Decide and design (or explicitly reject) a true rest-day state** — *M, needs a decision first*
`today_plan()` currently always resolves *some* session — there's no
backend concept of a scheduled rest day, so the "heroRest" state a design
mock once explored has no real data to render. Either (a) model rest days
properly (program-schedule change, see B1) and design for the state, or (b)
explicitly decide v1 doesn't need it and drop it from future design
iterations instead of re-deriving this question every redesign pass.
*Ref: Frontend Spec §4.4, PRD §11.*

**A5. Android visual QA pass** — *M*
Every design/implementation pass so far has been validated on iOS Simulator
only. Needs a real Android emulator/device pass before calling any screen
"done" cross-platform.
*Ref: Frontend Spec §8.*

---

## B. Product gaps surfaced by the PRD (backend + frontend)

**B1. Model rest days in the schedule, if A4 decides they're worth it** — *L*
Would touch `scheduled_workouts`/`program_days` generation logic
(`bootstrap_user_program`) to actually leave gap days rather than always
assigning a training day. Blocks A4 option (a).
*Ref: PRD §7.3 (implied), Frontend Spec §4.4.*

**B2. Surface the progression suggestion (`coach_next_load`)** — *M*
Computed correctly server-side, shown nowhere. Per PRD principle 5 (propose,
don't silently apply), this should render as an accept/reject affordance
beside the weight stepper in the log sheet — not silently overwrite
`prefill_kg`, which must keep showing what was actually lifted last time.
*Ref: PRD §7.3, HANDOFF.md §6.4.*

**B3. Coach-memory review UI** — *M*
`coach_memories` table exists, nothing reads/writes it meaningfully yet, no
UI shows or lets the user delete what's remembered. Build once the `remember`
tool (B7) is actually exercised and produces something worth reviewing —
sequencing matters here, don't build the UI before there's real data to show.
*Ref: PRD §7.3.*

**B4. Program periodization (mesocycles/deloads)** — *L, no near-term trigger*
`program_blocks` table exists, unused. Do not start this until plain
progressive-overload logic has demonstrably run out of road for the
founder's actual training — this is explicitly not a v1-timeframe ticket,
listed here only so it isn't reinvented from scratch later.
*Ref: PRD §7.3.*

**B5. Wearable / Apple Health / Google Fit sync** — *L, blocked on hardware*
Explicitly deferred until there's a device to validate against (PRD §7.3).
When unblocked: keep the `dataSource: manual | synced` shape per metric
rather than a parallel data model.
*Ref: PRD §7.2, §7.3.*

**B6. Monetization / billing** — *not sized, not scheduled*
No work until PRD §6's 4-week retention bar is met and public distribution
is actually being considered. Listed only so it isn't silently forgotten.
*Ref: PRD §7.4.*

---

## C. Coach/chat robustness (carried forward from HANDOFF.md, still open)

**C1. Golden-set regression test for the natural-language log parser** — *M*
~100 real utterances → expected proposal JSON, run on every deploy. This is
the part that silently breaks and where a regression corrupts real training
data — highest-value item in this section.

**C2. Streaming replies from the coach Edge Function** — *M*
Currently one blocking JSON response; longer answers read as slow.
`streamGenerateContent?alt=sse`.

**C3. `propose_swap` and `propose_program_change` tools** — *L*
Declared in the original design, not implemented — the coach can log sets
via chat but cannot yet change the plan itself through the same
propose→confirm safety path already built for logging.

**C4. Explicit Gemini context caching** — *S*
Currently relies on implicit prefix caching only. `cachedContents` needs
≥4096 tokens and TTL management to be worth doing — check real prompt sizes
before investing here.

**C5. Rolling thread summary** — *M*
`loadHistory` keeps the last 12 turns and drops the rest; long chat threads
lose earlier context entirely. Needs a summarization step, not just a
longer window (cost/latency tradeoff).

---

## D. Verification debt (never exercised — from HANDOFF.md §5)

Not features — these are real untested paths in the *current* build and
should be cleared before they're buried under new work:

- [ ] Onboarding end to end against a clean account, confirming
      `bootstrap_my_program` produces a sensible program.
- [ ] Full in-app logging flow (Today → session flow → log sets →
      celebration) on a completely fresh session — only the chat logging
      path has real verification history.
- [ ] Exercise swap from the injury banner mid-session (the exact path that
      exposed the `session_exercises` ordinal-uniqueness bug this session
      fixed — retest to confirm the fix holds under normal use, not just the
      case that surfaced it).
- [ ] Unit switching to imperial across every screen that shows a weight
      (conversion happens at the UI edge and in the coach's context pack —
      both need checking, not just one).
- [ ] Offline fallback: kill the coach Edge Function (or go offline) and
      confirm chat logging still works via the local regex parser.
- [ ] Deload/rest-day rendering when `scheduled_workouts` has nothing for
      today — not testable while a workout is always scheduled; shift a
      slot forward in SQL, check, restore. (Related to A4/B1 — if rest days
      get modeled properly, this becomes a real state instead of a SQL hack
      to test.)

---

## E. Accessibility (Frontend Spec §7 — real gap, not yet ticketed in detail)

**E1. Dynamic-type audit** — *M*
Test every fixed-size numeric display (steppers, count-up stats, hero
numbers) against large accessibility text sizes; fix clipping/overlap.

**E2. Screen-reader labeling pass** — *M*
Semantic labels on icon-only tap targets; text fallbacks for the
custom-painted rings/checks (splash mark, celebration ring, Today progress
ring) which currently have no non-visual representation at all.

**E3. Contrast audit against WCAG AA** — *S*
Palette is high-contrast by construction but has never been formally
checked. Quick pass, do alongside E1/E2 rather than as its own separate
effort.

---

## F. Security findings (from the Security & Access audit)

**F1. Add self-check to `bootstrap_user_program(uuid)`** — *S, do before any second account ever exists*
`security definer` function granted directly to `authenticated`, takes an
arbitrary `p_user_id` with no internal check that it matches the caller.
Currently harmless (one real account), but a genuine cross-tenant IDOR the
moment a second user exists — RLS doesn't apply inside a `security
definer` function, so the missing self-check is the only thing standing
between a caller and archiving/regenerating a stranger's program. Fix:
`if p_user_id <> auth.uid() then raise exception 'not authorized'; end if;`
as the first statement in the function body. No caller-visible behavior
change for the legitimate path (`bootstrap_my_program()`).
*Ref: Security & Access doc §5.1.*

**F2. Decide and scope data export / account deletion** — *L, legal weight — gate explicitly on "before public distribution"*
No end-to-end export or delete flow exists today. Not urgent at n=1; a hard
requirement, not a nice-to-have, before any public sign-up surface, under
GDPR/CCPA-adjacent expectations even informally.
*Ref: Security & Access doc §5.3, PRD §11.*

**F3. Email verification gate** — *S, bundle with the eventual sign-up surface, not before*
No enforcement that an email is verified before use. Low urgency until
there's a real public sign-up flow worth protecting — don't build ahead of
that need.
*Ref: Security & Access doc §5.2.*

---

## Sequencing note

A-section items are the ones that actually block or inform the next design
pass and should go first. B/C sections are real but not urgent — none of
them are load-bearing for "is the app good to keep using daily," which
remains the only metric that matters per PRD §6. D and E can run in
parallel with anything else; neither requires design input. **F1 is the one
item in this whole document worth doing out of order** — it's small, safe,
and the cost of forgetting it scales with however long it sits unfixed.
