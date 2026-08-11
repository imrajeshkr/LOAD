# LOAD — Product Requirements Document

**Status:** Draft v1 — first of five planning documents (PRD → Technical
Architecture → Security & Access → Frontend Specification → Feature Ticket
List), written before returning to design work. Supersedes the scope section
of `01-problem-validation-and-mvp.md`; that document's JTBD/competitive
research still holds and is carried forward, refined, below. This PRD is
written from first principles, informed by (but not bound by) the working
build on `main` — where the current implementation and the right product
call disagree, this document says so explicitly.

---

## 1. Product thesis

**LOAD is a training coach that reasons from a lifter's real, structured
history — not a logging app with a chatbot bolted on, and not a generic AI
chat with a fitness system prompt.**

The wedge is narrow on purpose: most fitness software is excellent at one of
two things — *recording* what happened (Strong, Hevy, JEFIT) or *generating*
a plan from a form (Fitbod, Freeletics) — and weak at the thing a real coach
actually does, which is holding a durable, correct model of one person and
adjusting a plan against it, indefinitely, with near-zero friction to log
today's work. LOAD's entire early roadmap is in service of that one loop
staying trustworthy and fast. Nothing else earns priority over it.

## 2. Users

### 2.1 v1 — real, narrow, non-negotiable

One user: the founder. LOAD v1 is built to be genuinely used, by its own
builder, in real training weeks — not to be demo-able or investor-ready.
Every v1 decision is graded against "would I actually keep using this
instead of a spreadsheet," not "would this look good on a landing page."

### 2.2 v2+ — aspirational, staged, not designed for yet

Anyone who wants an always-available, personalized strength coach and is
either priced out of a human trainer or unsatisfied with dumb logging apps.
Auth, RLS-scoped multi-tenant data, and the coach's proposal/confirm safety
model are already built multi-tenant-correct (see §7 and the Security &
Access doc) specifically so this transition doesn't require a data-model
rebuild — but v1 copy, onboarding, and support surface still assume a
single, known user. Do not build v2-only surface area (billing, admin
tooling, public marketing site, support inbox) until v1 has proven itself
per §6.

### 2.3 Explicit non-users for v1

- Anyone who isn't the founder. No invite flow, no waitlist, no public
  sign-up surface, even though the auth system technically allows a second
  account.
- Coaches/trainers managing other people's programs (no multi-athlete
  concept exists or is planned near-term).

## 3. Jobs to be done

Carried forward from the original validation pass, unchanged — this
research holds:

| Type | Job |
|---|---|
| Functional | "Tell me what to do in the gym today, tailored to my body and goals." |
| Functional | "Remember everything about me — injuries, equipment, history — so I never re-explain." |
| Functional | "Adjust the plan as I progress, plateau, or get hurt." |
| Emotional | "Hold me accountable — notice when I drift and say something." |
| Emotional | "Feel like a competent professional is actually looking after me, not a spreadsheet." |
| Functional (secondary) | "Let me ask it things in plain language when I need to, and have it actually know my context." |

The functional jobs are the product. The emotional jobs are what decide
whether it's still open in week 3 — see §6 metrics.

## 4. Competitive gap (why this, not an existing tool)

| Alternative | Gap |
|---|---|
| Human personal trainer | Expensive, scheduling friction, doesn't scale, tied to gym hours |
| Logging apps (Strong, Hevy, JEFIT) | Excellent tracking, zero intelligence — the user still has to know *what* to do |
| Generic AI chat (ChatGPT + a fitness prompt) | Can generate a plan once; no persistent structured memory, no logging integration, no proactive nudging, context re-fed by hand every session |
| Adaptive plan apps (Fitbod, Freeletics) | Shallow personalization (filters, not a real intake), subscription-gated, not conversational |
| Wearables + coaching (Whoop, Oura) | Rich data, thin actionable guidance — recommendations stay generic even with good input |

No competitor combines: (a) a real intake that builds durable personal
context, (b) a coach that proactively reasons and nudges rather than waiting
to be asked, (c) logging fast enough to survive contact with an actual gym
session, and (d) chat that's genuinely context-aware rather than a generic
overlay. That combination is the product.

## 5. Product principles

These are decisions already made and validated through building and using
v1 — stated here so they stop being re-litigated per feature, and so the
architecture/frontend docs that follow have a fixed reference point.

1. **Click, not type.** The primary logging path is tap-to-confirm
   pre-filled values, not data entry. Free-text is the escape hatch (chat),
   never the default path. If a screen's fastest interaction is typing a
   number, that screen is wrong.
2. **The session view shows one exercise and nothing else.** No tab bar, no
   secondary navigation, no unrelated content competing for attention
   mid-set. Everything not needed to complete *this* set is noise.
3. **Reward before you ask.** Post-session, the lifter sees what they did
   (numbers, comparison, a possible PR) before being asked how it felt or
   what hurt. Reflection follows achievement, not the other way round.
4. **Weekly cadence for body metrics, daily cadence for training.** Bodyweight
   is a noisy signal day-to-day; nudge for it roughly weekly, not daily.
   Training itself is the daily surface.
5. **The coach proposes, the system executes.** No model output writes
   training data directly — see the Security & Access doc for the full
   invariant. This is a product principle before it's a security control:
   trust is the entire product, and trust requires a human-legible confirm
   step between "the AI thinks you did this" and "this is now your
   permanent training record."
6. **Compare to the lifter's own last time, never to a static target.**
   Progress language ("+15 lb", "Same as last") is only meaningful measured
   against that same person's own history. Static baselines lie by omission.
7. **Warm, not clinical; personal, not generic-AI.** Explicitly not the
   orange-and-cream AI-chatbot aesthetic, not a sterile data dashboard. The
   product should read as a person who knows you, not a spreadsheet or a
   demo of "AI in fitness."
8. **Every visible number must trace to a real row.** No placeholder data,
   no synthetic demo content shipped as if real, in any surface a user
   might actually see mid-use. (Design mockups are the one legitimate
   exception, and even those get replaced with real states before ship.)

## 6. Success metrics

The original MVP doc defined a one-time "done" bar; a product graduating to
a real roadmap needs ongoing metrics, even at n=1:

| Metric | Why it matters | v1 target |
|---|---|---|
| Weeks of continuous real use without reverting to spreadsheet/memory | The actual validation signal — everything else is necessary but not sufficient | 4+ consecutive weeks |
| Time to log a set, session-view open to confirmed | Logging speed is a hard requirement, not a nice-to-have | under a napkin-and-pen's worth of friction — no fixed number, judged by "would I skip logging a set because this is slower than not bothering" |
| Sessions completed vs. sessions scheduled | Coach usefulness proxy — a plan nobody follows isn't personalized, it's ignored | trend upward over 4 weeks, not a fixed target yet |
| Proactive nudges acted on vs. dismissed | Whether the accountability JTBD is actually landing, not just present | qualitative for v1 — instrument the counts, don't optimize yet |
| Chat answers judged "specific to me" vs. "generic" by the user in the moment | The context-aware-chat JTBD is the hardest to fake; this catches regressions | no fixed number — treat any "that felt generic" moment as a bug |

No revenue, acquisition, or retention-cohort metrics for v1 — there is one
user. Do not build analytics infrastructure beyond what's needed to answer
the table above from real Postgres data already being written (session
history, nudge state, chat logs already exist as tables; this is query
work, not new instrumentation, for v1).

## 7. Feature scope

### 7.1 Already built and in real use (v1 core loop — see Technical
Architecture doc for implementation detail)

- Auth: Google Sign-In + email/password, no forgot-password flow yet
  (explicitly deferred, §8).
- Guided onboarding producing a structured profile (goal, experience,
  environment, days/week, split preference, injuries/constraints).
- Auto-generated training program from the catalog, injury-aware
  (severe-stress movements excluded, moderate ones flagged with a
  swap offered, not blocked).
- Today screen: hero card (active / complete states), momentum line, weekly
  weigh-in nudge, protein progress + quick-log, missed-session nudge,
  post-session breakdown with per-exercise deltas vs. last time, "Up next"
  preview of the following scheduled session.
- Full-screen, no-nav session flow: guidance-first exercise page with a
  real demo image and form cues, pre-filled log sheet (uniform or per-set),
  non-blocking rest timer with auto-advance, exit-confirm gated on whether
  anything was actually logged.
- Post-session celebration: reward-first ordering (numbers, comparison,
  possible PR) before reflection (RPE, pain, optional note).
- Progress tab: bodyweight trend (raw + 7-day average), per-exercise
  strength trend, session history, consistency/streak.
- Coach chat: context-aware Q&A grounded in the real profile and recent
  history; natural-language logging via a propose → confirm flow;
  exercise-swap suggestions.
- Profile/Settings: permanent weigh-in card, editable onboarding fields,
  units (metric/imperial).

### 7.2 Explicitly cut from v1 (carried forward, still correct)

| Cut | Why |
|---|---|
| Nutrition/meal logging beyond protein | Full nutrition tracking is its own product surface; protein-only is the health proxy that matters most for the stated goal (build muscle / recomposition) without becoming a second app |
| Wearable / Apple Health / Google Fit sync | Wanted, no hardware to validate against yet — data model stays extensible (see §7.3), integration itself stays out |
| Social features (sharing, friends, leaderboards) | Not needed to prove the core loop for a single user; premature for an app with one user |
| Forgot-password flow | Single known user; founder resets manually if ever needed |
| Video form-check / computer vision | Separate, hard problem; static demo image + text cues cover the JTBD adequately for v1 |
| Full periodization science (mesocycles, deloads as a formal system) | `program_blocks` table exists in schema for this; unused until progressive-overload logic alone proves insufficient |
| ML-tuned notification timing | Rule-based nudges first; tune only once there's real usage data to tune against |
| Monetization / billing | See §7.4 |
| Any multi-user-facing surface (invite flow, admin tooling, support inbox) | Premature for a one-user product — see §2.3 |

### 7.3 Deferred with intent (schema-ready, not built)

- **Wearable sync.** Keep a `dataSource: manual | synced` shape available
  per metric so this slots in later without a data-model rebuild.
- **Coach memory review.** `coach_memories` table exists; no UI shows or
  lets the user delete what's been remembered. Build once the coach is
  actually writing meaningful memories worth reviewing.
- **Program periodization.** `program_blocks` exists, unused.
- **Progression suggestion surfaced explicitly.** `coach_next_load` is
  computed correctly server-side and shown nowhere; `prefill_kg`
  deliberately shows *last lifted*, not the suggestion, so a real product
  decision (surface it as an accept/reject alongside the stepper, per
  principle 5) is still open — see Feature Ticket List.

### 7.4 Monetization — recommendation, not yet decided

No monetization in v1: there's one user, and it's free to run at this
scale. Recommendation for v2, when/if it opens to more users: a simple
paid tier (subscription) gated on the coach chat + adaptive planning,
with manual logging usable for free — mirrors the actual cost driver (LLM
calls) to the actual value driver (the intelligence layer, not the
tracker). This is a placeholder recommendation, not a commitment; revisit
only once §6's 4-week bar is met and public distribution is actually being
considered, not before.

## 8. Non-goals (v1, restated plainly)

- Not a general-purpose fitness content platform (no articles, no video
  library beyond per-exercise form cues).
- Not a nutrition/calorie-tracking app.
- Not a social network.
- Not a marketplace for human trainers.
- Not built for iPad/tablet/web layouts — native mobile only (§9).
- Not multi-athlete / coach-managing-clients.

## 9. Platform

Native mobile only (Flutter, iOS + Android from one codebase — already the
implementation choice and correct to keep). No responsive web layout, no
tablet-optimized layout. Design and frontend spec should assume native
mobile conventions throughout — see the Frontend Specification doc.

## 10. Risks carried forward

- **Safety/liability.** Exercise and injury guidance isn't neutral content —
  the coach must stay conservative on progression, flag pain rather than
  push through it, and never present itself as medical advice. This is a
  content/behavior requirement on the coach's system prompt and is also a
  hard technical invariant — see Security & Access doc §"AI write safety."
- **Hallucination.** The coach must reason from real injected structured
  context (profile, history), never free-associate a plan that ignores
  stated constraints. Already mitigated by the RLS-scoped context-fetch
  design; stays a standing risk to test against as prompts change.
- **Scope creep.** "Know everything relevant to a coach" is unbounded by
  nature. The fixed profile schema in the Technical Architecture doc is the
  boundary — new fields require a deliberate schema change, not an
  ad hoc addition to a JSON blob.
- **Retention.** Fitness apps have poor usage curves industry-wide even for
  n=1. §6's 4-week metric exists specifically to catch this early rather
  than assume the product is fine because it was fun to build.

## 11. Open questions for the next docs to resolve, not this one

- Exact data retention / deletion policy for a user who stops using the
  app (Security & Access doc).
- Whether the coach's Gemini dependency needs a fallback provider or is an
  acceptable single point of failure for v1 (Technical Architecture doc).
- Whether the "Up next" / progression-suggestion surfaces need push
  notifications or stay in-app-only for v1 (Frontend Specification doc).

---

*Next: `04-technical-architecture.md`.*
