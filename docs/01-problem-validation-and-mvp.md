# My-Trainer — Problem Validation & MVP Scope

Inputs locked from founder Q&A (2026-08-10):
- **User v1:** solo (founder), but auth built in from day 1 for future public distribution
- **Auth:** Google Sign-In + Email/Password (with confirm-password on signup). No forgot-password flow yet.
- **Platform:** Native mobile app only (no web v1)
- **Interaction model:** Structured coaching is the core job. Chat is secondary, but must be context-aware (knows the user's real profile/history, not generic).
- **Data input:** Manual profile + manual logging for MVP. Wearable/health-app sync is wanted but deferred — no wearable hardware to test against yet. Data model should stay extensible toward it, but it is not built now.

---

## 1. Problem / Idea Validation

### 1.1 Who is this for

**v1 (real):** A single user (founder) who trains and wants a coach-level system that knows their body, history, constraints, and goals — instead of a generic tracker or a human trainer they have to keep re-briefing.

**v2+ (aspirational, not designed for yet):** Anyone who wants an always-available, personalized fitness coach — priced out of or inconvenienced by human trainers, or dissatisfied with dumb logging apps.

Keep these separate. The MVP is built to solve the founder's own problem convincingly. Auth exists now only so the door is open later — it does not mean v1 should be designed for a general audience.

### 1.2 Jobs to be Done

| Type | Job |
|---|---|
| Functional | "Tell me what to do in the gym today, tailored to my body and goals." |
| Functional | "Remember everything about me — injuries, equipment, history — so I never re-explain." |
| Functional | "Adjust the plan as I progress, plateau, or get hurt." |
| Emotional | "Hold me accountable — notice when I drift and say something." |
| Emotional | "Feel like a competent professional is actually looking after me, not a spreadsheet." |
| Functional (secondary) | "Let me ask it things in plain language when I need to, and have it actually know my context." |

The functional jobs are the product. The emotional jobs (accountability, trust) are what make or break retention — fitness apps live or die on whether they get used in week 3, not week 1.

### 1.3 Why existing options fall short

| Alternative | Gap |
|---|---|
| Human personal trainer | Expensive, scheduling friction, quality varies, doesn't scale, tied to gym location/hours |
| Logging apps (Strong, Hevy, JEFIT) | Excellent at tracking, zero intelligence — user still has to know *what* to do and *why* |
| Generic AI chat (ChatGPT w/ fitness prompts) | Can generate a plan, but no persistent structured memory, no logging integration, no proactive nudging — user manually re-feeds context every time |
| Adaptive plan apps (Fitbod, Freeletics) | Some personalization, but shallow (equipment/goal filters, not a real intake), subscription-gated, not conversational, doesn't ask clarifying questions like a real coach would |
| Wearable + coaching (Whoop, Oura) | Rich data, thin actionable guidance; recommendations stay generic even with good data |

**The actual gap:** nothing combines (a) a real intake that builds durable personal context, (b) a coach that proactively reasons and nudges instead of waiting to be asked, (c) fast/low-friction logging, and (d) chat access that's genuinely context-aware — in one app.

### 1.4 Is it worth building

Yes, independent of market size — it solves the founder's own problem, which is sufficient justification for v1. No external validation is required before building; the validation happens by the founder using it in real training weeks. Broader-market validation (is this worth productizing) is a v2 question, answered *after* v1 proves out on real use, not before.

### 1.5 Risks to design around, not ignore

- **Safety/liability:** exercise and injury guidance is not neutral content — the coach must default to conservative progression, flag pain reports instead of pushing through them, and avoid presenting itself as medical advice.
- **Hallucination risk:** the model must reason from the user's actual logged profile/history (injected as structured context), not free-associate a generic plan that ignores stated constraints.
- **Scope creep:** "know everything relevant to a fitness coach" is unbounded. MVP must ship with a fixed, explicit profile schema (below) — not an open-ended memory system.
- **Retention risk:** fitness apps have poor long-term usage curves industry-wide. Nudging and low-friction logging matter more for real-world success than plan sophistication.

---

## 2. MVP Scope — the one core loop

Everything in the MVP exists to make this loop work end to end, at real product quality:

```
Onboarding (once) → Plan generation → Daily session (see it, log it) → Adapt → Nudge
                                              ↑______________________________|
                                    (secondary, always available: context-aware chat)
```

### 2.1 Onboarding — building the profile the coach needs

A guided intake (not a giant form dump) that produces a structured profile:

- **Body/goal:** age, sex, height, current weight, goal (build muscle / lose fat / recomposition / general health / strength)
- **Training background:** experience level, current routine if any, days/week available, session length
- **Environment:** home / commercial gym / bodyweight-only, and what equipment is actually available
- **Constraints:** injuries, mobility limits, relevant medical conditions, dietary restrictions
- **Preferences:** liked/disliked exercises, split preference if the user has one

This is the "ask something it doesn't have" behavior made concrete — the intake should surface gaps and ask, not assume defaults silently.

### 2.2 Plan generation

Coach produces an initial personalized weekly training plan (split, exercises, sets/reps, starting loads/progression scheme) derived from the profile above — this is the first real coach output, not a template picker.

### 2.3 Daily session — the core interaction

- "Today" view: today's exercises with target sets/reps/weight (weight/reps informed by logged history, not static)
- Fast set logging: weight × reps (RPE optional) — must be quick enough to use *between sets*, not after the gym
- Mark session complete

Logging speed is a hard requirement, not a nice-to-have — if logging is slower than writing it on a napkin, the app dies in week 2.

### 2.4 Adaptation

After each logged session (or a missed one), the coach updates:
- Progression: increase load/reps when targets are hit
- Regression/deload: when performance drops or pain/soreness is reported
- Periodic plan refresh as history accumulates

### 2.5 Nudges (proactive, not user-triggered)

- Missed-session nudge (user's own logged pattern, e.g. "usually trains Tue/Thu/Sat — Thursday isn't logged yet")
- Consistency/streak nudges
- Data-gap check-ins ("haven't logged weight in 2 weeks") — the coach asking for what it needs, matching the founder's original JTBD

### 2.6 Chat — secondary, but context-aware

Available any time, but not the primary interaction surface. Must have access to the full profile + recent history so answers are specific ("you have a bad left knee, skip that" / "you don't have cables today, here's the swap"), never generic fitness-Q&A.

---

## 3. Explicitly cut from MVP

Cutting these is what keeps this an actual MVP instead of a rebuild of every fitness app at once. Each has a reason, not just "later":

| Cut | Why |
|---|---|
| Nutrition/meal logging | Full scope on its own; MVP tracks weight only as the health proxy |
| Wearable / Apple Health / Google Fit sync | Wanted, but no hardware to build/test against yet — deferred, not designed away (see 4.1) |
| Social features (sharing, friends, leaderboards) | Not needed to prove the core loop for a single user |
| Forgot-password flow | Explicitly deferred by founder |
| Video form-check / computer vision | Separate, hard problem; not core to "tell me what to do and track it" |
| Full periodization science | Enough progressive-overload logic to be correct and safe, not a sports-science engine |
| Smart notification timing (ML-tuned nudges) | Start with simple rule-based nudges; tune later with real usage data |

## 4. Not cut, but deferred with intent

### 4.1 Wearable sync
Keep the profile/data schema extensible (e.g. a `dataSource: manual | synced` field per metric) so this slots in later without a rebuild — but don't build the integration or any UI for it until there's a device to validate against.

### 4.2 Public distribution
Auth (Google + email/password) is built now specifically so this doesn't require a rebuild later. Nothing else about v1 (data model, plan logic, UI copy) should assume multi-tenant use yet.

---

## 5. MVP "done" — what proves or disproves this

The MVP is complete and worth evaluating when the founder can:

1. Complete onboarding once and get a plan that's actually usable, not a placeholder
2. Log a full real gym session without the app being slower than pen-and-paper
3. Receive at least one genuinely useful proactive nudge in the first week
4. Ask the coach an ad hoc question mid-week and get an answer that reflects real profile/history, not a generic response
5. Still be using it — not reverted to spreadsheet/memory/old habits — after 2–4 weeks of real training

That last point is the actual validation signal. Everything before it is necessary but not sufficient.

---

## 6. Design Inputs (for the design pass)

### 6.1 Screens to cover (derived from the core loop in Section 2)

1. **Onboarding / intake** — guided, question-by-question, not a long form. Should visibly feel like the coach is *asking* rather than the user *filling*.
2. **Today / plan view** — the daily landing screen: today's session, exercises, targets. This is the screen used most, every single day — it should get the most design attention.
3. **Logging** — mid-workout, quick set entry. Design for one-handed use, between sets, minimal taps.
4. **Progress / history** — lightweight view of past sessions, weight trend, progression over time.
5. **Chat** — secondary surface, always reachable, but not competing with the Today view for primary real estate.
6. **Nudges** — not a screen, but a pattern: how a proactive nudge shows up (push notification content, in-app banner/card) needs a design decision, not just a today-view afterthought.
7. **Auth** — Google sign-in + email/password w/ confirm-password, standard but should match the rest of the visual system.

### 6.2 Style direction

No fixed direction yet — asked Claude (design session) to propose 2–3 visual directions to react to, spanning roughly:
- **Minimal & clinical** (Apple Health / Whoop-like — calm, data-forward, lots of white space, feels precise/trustworthy)
- **Bold & energetic** (gym-brand feel — strong contrast, dark backgrounds, punchy accent color, feels motivating)
- **Warm & coach-like** (friendly, conversational, softer colors, more personality — feels like a person, not a dashboard)

Pick after seeing concrete mockups/comps, not in the abstract.

### 6.3 Platform constraint

Native mobile only (see top of doc) — design should assume native mobile UI conventions (iOS/Android patterns), not responsive web layout.
