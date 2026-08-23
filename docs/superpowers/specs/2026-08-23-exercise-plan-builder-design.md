# Exercise Plan Builder — Design

**Date:** 2026-08-23 · **Status:** design, not yet approved · **Scope:** catalog, generation, progression, transitions, swap, onboarding intake

---

## 1. Where we are today

`bootstrap_user_program()` builds a plan in one pass:

```mermaid
flowchart LR
  A[training_profiles] --> B[split → pattern array<br/>one pattern per day]
  B --> C[per day: filter catalog<br/>pattern + equipment + injury]
  C --> D[DISTINCT ON primary muscle<br/>ORDER BY rep_low, slug<br/>LIMIT 4]
  D --> E[hardcoded sets/reps/rest]
  E --> F[start load → snap to plates]
  F --> G[weekday slots + 35-day schedule]
```

It works for one split and quietly fails for the other two.

### Two live bugs

The split→pattern map (verified on the production function, not just the migration):

| Split | Needs | Generator emits | Result |
|---|---|---|---|
| `push_pull_legs` | push · pull · legs | `{push, pull, legs}` | ✅ correct |
| `upper_lower` | Upper = push+pull, Lower = legs | `{push, legs}` | ❌ **no back/pull work at all** |
| `full_body` | all muscles across 2 days | `{push, pull}` | ❌ **legs never appear** |

All 8 live programs are PPL, so nobody is broken *today*. But the split toggle shipped this week makes `full_body`/`upper_lower` one tap from Profile — this turns live on the next tap.

**These are symptoms, not the disease.** The generator assumes *one pattern per day* and *exactly 4 exercises*. That happens to be right for PPL because each pattern has exactly 4 primary muscles. An Upper day spans 8 muscles; a full-body day spans 12. Fixing the arrays alone can't fix that.

### Design gaps

1. **Goals are collected, stored, and ignored.** "Build muscle" and "Get stronger" generate identical plans.
2. **No weekly volume planning.** Progress judges you against a 10–20 sets/muscle/week band the generator never targets. Volume is an accident.
3. **Selection is alphabetical.** `ORDER BY default_rep_low, slug` is a compound-first *proxy*; no quality ranking, no antagonist balance, no cross-day variety.
4. **Fixed 4 exercises, fixed set counts**, regardless of day count, experience, or goal.
5. **Every user is treated as intermediate in a commercial gym** — see below.
6. **`load_type` filtered to 2 of 6 values**, so timed/assisted/weighted-bodyweight movements can never enter a plan.

---

## 2. What we already have and don't use

The schema anticipated most of this. It's wired to nothing.

| Field | Values | Asked in onboarding? | Used by generator? |
|---|---|---|---|
| `experience` | beginner · intermediate · advanced | ❌ never → **NULL** | ❌ |
| `environment` | commercial_gym · home_gym · bodyweight_only | ❌ never → **NULL** | ⚠️ read, but defaults to `commercial_gym` |
| `goals` | build_muscle, strength, lose_fat, general_health | ✅ **populated for every user** | ❌ |
| `mechanic` | — | — | ❌ column doesn't exist yet |

Two consequences worth stating plainly:

- **Every home-gym user currently gets commercial-gym machine picks**, because `environment` is NULL and the generator coalesces to `commercial_gym`.
- **The goals screen is not the problem.** It collects good data (`{build_muscle,strength}`, `{build_muscle,lose_fat}`…). Keep it — and start using it. Nothing gets removed from onboarding; two questions get *added*.

---

## 3. Target architecture

The core inversion: stop picking *exercises per pattern*, start allocating *sets per muscle per week*, then fill those sets with exercises.

```mermaid
flowchart TD
  subgraph Intake
    A1[experience] --> P
    A2[environment] --> P
    A3[goals] --> P
    A4[days + split] --> P
    A5[injuries] --> P
    A6[bar/plates + bench cal.] --> P
  end
  P[Plan Builder]
  P --> V[1 · Weekly volume budget<br/>sets per muscle group]
  V --> S[2 · Split the budget<br/>across training days]
  S --> X[3 · Fill each day<br/>scored exercise selection]
  X --> R[4 · Prescribe<br/>sets · reps · rest]
  R --> L[5 · Start loads<br/>by experience]
  L --> OUT[(program_days +<br/>program_day_exercises)]
  OUT --> PR[Runtime progression<br/>experience-tuned]
  OUT --> SW[Swap<br/>same-muscle alternatives]
```

Each stage is independently testable, which the current single-query design is not.

---

## 4. The catalog

### Source

[`yuhonas/free-exercise-db`](https://github.com/yuhonas/free-exercise-db) — **873 exercises, The Unlicense (public domain), 1.8k stars.** Verified structure and distributions:

| Field | Distinct values | Notes |
|---|---|---|
| `level` | beginner 523 · intermediate 293 · expert 57 | → maps to our `experience_level` |
| `mechanic` | compound 489 · isolation 297 · null 87 | **the compound-first signal we currently fake** |
| `force` | pull 371 · push 369 · static 104 | helps derive `pattern` |
| `equipment` | 13 values | barbell 170, dumbbell 123, body only 111, cable 81, machine 67… |
| `primaryMuscles` | 17 values | quadriceps 148, shoulders 127, abdominals 93… |
| `category` | 7 values | strength 581, powerlifting 38 → **619 usable**; drop stretching/cardio/plyo |
| `images` | 2 per exercise | usable for the guide screen |

### Two tiers — this is the key decision

Importing 873 rows does **not** mean the generator picks from 873. The dataset lacks the metadata our safety and volume logic depend on (joint stress, muscle contribution, start loads, rep ranges). Authoring that for 619 exercises is weeks of work; authoring it for the ~150 that matter is days.

```mermaid
flowchart LR
  D[(free-exercise-db<br/>873)] --> F{category filter}
  F -->|strength + powerlifting| U[619 imported]
  F -->|stretching, cardio,<br/>plyo, olympic, strongman| SKIP[not imported]
  U --> T{enrichment tier}
  T -->|~150 core| C[**Core**<br/>fully enriched<br/>generator-eligible]
  T -->|~470 extended| E[**Extended**<br/>dataset fields only<br/>swap + browse only]
```

- **Core (~150):** joint stress, muscle contribution, rep ranges, start loads, weight step, unilateral flag — all authored. Only these can be *auto-selected* into a plan.
- **Extended (~470):** imported as-is. Surfaced in swap and search, flagged "we know less about this one." A user can opt into them; the generator never picks them unprompted.

A boolean `is_core` on `exercises` gates this. It also gives us a growth path: promote Extended → Core over time without re-importing.

### Field mapping

| Dataset | Ours | Rule |
|---|---|---|
| `name` | `name`, `slug` | slugify; dedupe against existing 40 by slug + alias |
| `level` | `min_experience` *(new)* | expert → `advanced` |
| `mechanic` | `mechanic` *(new)* | null → infer from primary-muscle count |
| `force` + `primaryMuscles` | `pattern` | push/pull/legs/core decision table |
| `equipment` | `exercise_equipment` | 13 → our 9 slugs; `e-z curl bar`→barbell, `bands`→new, ball/foam/other→Extended only |
| `primaryMuscles` | `exercise_muscles(role=primary)` | 17 → our 18; see delt problem below |
| `secondaryMuscles` | `exercise_muscles(role=secondary)` | contribution 0.5 default, authored for Core |
| `instructions` | `description` | joined |
| `images` | `demo_path` | optional mirror to our bucket |

**The delt problem.** The dataset lumps 127 exercises as `shoulders`; we split Front/Side/Rear Delt — a split our volume logic depends on. Resolution: keyword rules on the name (`lateral raise`→side, `rear delt`/`reverse fly`→rear, `overhead press`/`front raise`→front), then **manual review of the shoulder subset inside Core only**. Extended shoulder entries keep a generic Shoulders mapping.

**Not in the dataset, must be authored for Core:** joint stress (our injury routing is meaningless without it), muscle contribution weights, `default_rep_low/high`, `default_start_kg`, `weight_step_kg`, `is_unilateral`.

---

## 5. The user model

Three axes, all already in the schema:

```mermaid
flowchart LR
  E[experience<br/>beginner · intermediate · advanced] --> PLAN
  V[environment<br/>commercial · home · bodyweight] --> PLAN
  G[goals<br/>muscle · strength · fat loss · health] --> PLAN
  PLAN[plan shape]
  E -.controls.-> E1[which exercises are allowed<br/>volume ceiling<br/>start loads<br/>progression rate]
  V -.controls.-> V1[which equipment exists]
  G -.controls.-> G1[rep ranges<br/>rest<br/>volume distribution]
```

**Experience gates exercise difficulty.** A beginner never gets an `expert`-level lift auto-selected. Rule: `exercise.min_experience <= user.experience`. Advanced users still see beginner lifts (they're staples, not training wheels).

---

## 6. Generation algorithm

### Stage 1 — weekly volume budget

Hard sets per muscle group per week, by experience:

| Experience | Sets/muscle/week | Rationale |
|---|---|---|
| Beginner | 8–10 | Technique and recovery are the limiter, not volume |
| Intermediate | 12–16 | The productive middle |
| Advanced | 16–20 | Needs more stimulus to progress |

Goal modifies distribution, not the ceiling:

| Goal | Rep range | Rest | Volume note |
|---|---|---|---|
| `build_muscle` | 6–12 | 90–120s | Full budget |
| `strength` | 3–6 | 180s | −20% volume, compounds weighted heavily |
| `lose_fat` | 10–15 | 60–90s | Full budget (preserve mass), shorter rest |
| `general_health` | 8–15 | 90s | Low end of the budget |

Multiple goals: the **first-picked goal leads** (onboarding already captures order), others blend at half weight.

### Stage 2 — split the budget across days

Each split defines a **muscle set per day**, not a single pattern:

| Split | Day types | Muscles per day |
|---|---|---|
| `push_pull_legs` | Push · Pull · Legs | 4 · 4 · 4 |
| `upper_lower` | Upper · Lower | **8** · 4 (+core) |
| `full_body` | Full A · Full B | ~6 each, alternating emphasis |

Weekly budget ÷ days that train a muscle = sets per muscle per session. This is where the current design breaks and the new one doesn't: the day is defined by *muscles to cover*, and exercise count follows from that (capped 4–6 for session length) instead of being hardcoded.

### Stage 3 — scored selection

```mermaid
flowchart TD
  A[Core catalog] --> F1{equipment ∈ environment?}
  F1 -->|no| X[reject]
  F1 -->|yes| F2{min_experience ≤ user?}
  F2 -->|no| X
  F2 -->|yes| F3{severe joint stress<br/>on an active constraint?}
  F3 -->|yes| X
  F3 -->|no| S[score]
  S --> S1[+ muscle still under<br/>weekly target]
  S --> S2[+ compound, for<br/>opening slots]
  S --> S3[+ quality tier]
  S --> S4[− already used<br/>this week]
  S1 & S2 & S3 & S4 --> P[pick highest,<br/>decrement budget,<br/>repeat]
```

Hard filters stay hard (safety and availability are not negotiable). Everything else becomes a score, so selection degrades gracefully — a bodyweight-only user with a shoulder flag still gets a coherent plan instead of an empty day.

### Stage 4 — prescription

Sets, reps, and rest come from the goal table above; set count per exercise falls out of the per-session muscle budget. Compounds open the session, isolation closes it (now driven by `mechanic`, not a rep-range proxy).

### Stage 5 — starting loads

| Experience | Barbell | Other |
|---|---|---|
| Beginner | Empty bar | 0.4 × catalog default |
| Intermediate | Catalog default, or history | Catalog default |
| Advanced | History-driven; catalog default as floor | History-driven |

Bench calibration (already built) overrides for bench. All loads snap to loadable plates (already built).

---

## 7. Progression by experience

> **Implemented by `v2_0030` (applied).** `train_screen()` now branches on
> experience: beginners progress linearly, intermediates keep double
> progression, and advanced lifters get the reactive deload that did not exist
> before. The deload needs no schema and no dismissal state — it is derived from
> the last three sessions and delivered as the prefilled weight, so §13.5's
> "always skippable" is satisfied by the user typing a different number, and it
> self-clears once a lighter session is logged. Copy is asserted free of the
> word "deload" and of any tier name (§13.7) by
> `supabase/tests/v2_0030_progression_test.sql`.
>
> `v2_0031` closes a related hole found while testing: `experience` and
> `environment` were landing NULL again on rows written by app builds released
> before Plan 01, which omit those keys entirely. The columns now carry
> DEFAULTs, so the guarantee no longer depends on which client version a user
> happens to be running.

The runtime half — `train_screen()` already does double progression, but with one hardcoded rule for everyone. Parameterize it:

| Experience | Scheme | Increment | Stall handling |
|---|---|---|---|
| **Beginner** | Linear per session | +2.5kg upper · +5kg lower | Repeat the weight |
| **Intermediate** | Double progression (current) | +1 loadable step at top of range with RIR ≥ 1 | Hold, then Progress flags it |
| **Advanced** | Double progression, slower | +1 step, or rep-only if RIR 0 | **Deload 10% after 3 stalled sessions** |

Beginners adapt session-to-session and should be loaded that way; advanced lifters need the deload branch we don't have at all today.

---

## 8. Transitions — how a user moves between states

Everything above describes a *snapshot*: given a user's state, build a plan. This section covers the part that actually decides whether the app is any good a year in — **how state changes over time**, and what happens to the plan when it does.

Two independent kinds of transition:

- **Level transition** — beginner → intermediate → advanced. The app proposes it; the user accepts.
- **Shape transition** — N days → M days, PPL → Upper/Lower → Full body. The user initiates it.

### 8.1 Level transition is earned, not timed

Training age is not calendar time. The honest definition is **which progression scheme still works**:

| Level | Definition | Progression that still works |
|---|---|---|
| Beginner | Can add weight almost every session | Linear, per session |
| Intermediate | Needs a week to add weight | Double progression, per week |
| Advanced | Needs multi-week blocks to add weight | Blocks with planned deloads |

That makes the detector fall out for free: **a beginner graduates when linear progression stops paying.** We already compute exactly that in `lift_status(...)`.

```mermaid
stateDiagram-v2
    [*] --> Beginner
    Beginner --> Intermediate: auto-proposed
    Intermediate --> Advanced: proposed, needs intent
    Intermediate --> Returning: pause, or 3+ weeks silent
    Advanced --> Returning: pause, or 3+ weeks silent
    Returning --> Intermediate: ramp complete
    Returning --> Advanced: ramp complete
```

**Beginner → Intermediate.** All three must hold, so one bad fortnight can't promote anyone:

1. ≥2 main compound lifts return `stalled` from `lift_status`, **and**
2. ≥8 weeks of logged training, **and**
3. the stall survived one deload — proving it's adaptation, not fatigue.

**Intermediate → Advanced.** Deliberately *not* automatic. Signals worth surfacing (≥18 months consistent, main lifts gaining < ~1 kg/month, strength standards relative to bodyweight), but advanced means more volume and scheduled deloads. That needs consent — and per §13.7 we ask for consent to the *behaviour* ("a lighter week every fourth week, and a bit more volume"), never to the label.

**No automatic demotion.** Thresholds and return behaviour differ for a declared pause vs. silent absence — see §13.8. A long layoff doesn't make someone a beginner again — it makes them a trained person who is detrained. That's the `Returning` state: keep the level, re-ramp volume and loads (§8.3), exit the ramp back to where they were.

### 8.2 A transition is a proposal, never an ambush

Silently rebuilding someone's plan because a threshold tripped is the wrong behaviour. Transitions arrive through the coach channel that already exists:

> Your squat has sat at 80 kg for three sessions and bench for four. That isn't failure — it's beginner progression finishing its job. Want me to move you up? More weekly volume, and weight climbs across the week instead of every session.

Accept → transition. Decline → snooze and re-evaluate in 4 weeks.

On accept we **close the current `training_profiles` row (`valid_to = today`) and insert a new one** — using the versioning that's been sitting unused. That gives a real audit trail of the user's journey for free, and lets Progress eventually show "you became an intermediate lifter in March."

### 8.3 Shape transitions — N days → M days, split → split

Today `generateProgram()` archives the old program and builds a new one from scratch. Three things go wrong, and all three are invisible to the user.

```mermaid
flowchart TD
  T[shape change requested] --> D{how big?}
  D -->|days ±1, same split| MINOR[rebuild, keep lifts]
  D -->|split change, or days +2 or more| MAJOR[rebuild + ramp + optional deload]
  MINOR --> C[continuity pass]
  MAJOR --> C
  C --> R[volume ramp<br/>if new volume > old + 30%]
  R --> DIFF[show kept / added / dropped]
  DIFF --> OUT[(new program)]
```

**1 · Continuity — keep the lifts you're mid-progress on.** Selection gains a `+continuity` score term: an exercise the user has logged recently, which still fits the new plan's muscle budget and filters, keeps its slot **and its working load**. Only genuinely new slots start from catalog defaults. Loads already survive via the history lookup; what's missing is *slot* stability.

**2 · Volume ramp — never double someone's week overnight.** Going 3 → 6 days roughly doubles weekly sets, which is how people get hurt. If new weekly volume exceeds old by more than 30%:

| Week | Volume |
|---|---|
| 1 | old + 50% of the increase |
| 2 | full target |

Implemented as a `ramp_factor` applied at `train_screen()` time, derived from days since the program started — **no schema change, and it self-expires.**

**3 · Deload on structural change.** A split change or +2 days is a natural moment for one light week. Reuses the Phase 4 deload mechanic rather than inventing a second one.

**4 · Show the diff.** The rebuild confirm I shipped this week says only "new sessions and exercises." It should say what actually happens: **kept** Bench, Squat, Row · **added** Incline press, Leg curl · **dropped** Cable fly. This is the single cheapest trust win in the whole design.

**5 · Mid-week changes.** Already forward-only, which is right — past days are history. The current week ends up hybrid, and that's fine: the ramp counts from the transition date, and the week's remaining days run the new plan at ramp week 1.

### 8.4 Program lifecycle — the deeper gap

A program today runs **forever**; only loads move. That's correct for a beginner (linear progression *is* the program) and wrong for everyone else — real training runs in blocks, then changes.

`programs.ends_on` exists and is unused. Proposal:

| Level | Block length | What happens at the end |
|---|---|---|
| Beginner | none | Runs until linear progression stalls — that stall *is* the block boundary, and it triggers §8.1 |
| Intermediate | 6 weeks | Deload week, then regenerate: keep main lifts, vary 1–2 accessories |
| Advanced | 4 weeks | Volume wave + planned deload, then regenerate |

This is the honest answer to "how does the plan change over time," and load progression alone is not that answer. It's the largest single piece of remaining work, so it lands last (Phase 6) — but it needs naming now, because the level model in §8.1 only makes sense if blocks eventually exist.

---

## 9. Exercise swap

"Sure could swap the exercise if they want to do a different one for the same muscle."

- Entry point: tap an exercise in the Train tab plan list → **Swap**.
- Candidates: same primary muscle, passing the same hard filters (equipment, experience, injury). **Core ranked first, Extended below a divider** with a "less data" note.
- Persistence: writes an override on `program_day_exercises` — survives regeneration unless the split changes.
- Load carry-over: the new exercise starts from its own history if present, else its catalog default. Never inherits the replaced lift's weight.

---

## 10. Onboarding changes

Current steps: `goal · body · days · bar · map · review`.

- **Keep `goal`** — now actually drives rep ranges, rest, and volume.
- **Add `experience`** — "How long have you trained consistently?" → `<6 months` / `6 months–2 years` / `2+ years`. Editable later in Profile.
- **Add `environment`** — "Where do you train?" → commercial gym / home gym / bodyweight only. Fixes the silent commercial-gym default.

Two new taps, both single-select. Existing users default to `intermediate` + `commercial_gym` (today's implicit behavior) and get prompted once in Profile.

---

## 11. Data model changes

```sql
-- exercises
ALTER TABLE exercises
  ADD COLUMN min_experience experience_level DEFAULT 'beginner',
  ADD COLUMN mechanic       text,      -- compound | isolation
  ADD COLUMN force          text,      -- push | pull | static
  ADD COLUMN is_core        boolean NOT NULL DEFAULT false,
  ADD COLUMN source         text;      -- 'load' | 'free-exercise-db'

-- program_day_exercises
ALTER TABLE program_day_exercises
  ADD COLUMN swapped_from_exercise_id uuid REFERENCES exercises(id),
  ADD COLUMN is_user_choice boolean NOT NULL DEFAULT false;

-- programs: which generator built this, so §13.1 can migrate in waves
ALTER TABLE programs
  ADD COLUMN generator_version int NOT NULL DEFAULT 1;

-- new: volume targets, so tuning doesn't need a migration
CREATE TABLE volume_targets (
  experience experience_level NOT NULL,
  goal       goal_type        NOT NULL,
  sets_min   int NOT NULL,
  sets_max   int NOT NULL,
  rep_low    int NOT NULL,
  rep_high   int NOT NULL,
  rest_sec   int NOT NULL,
  PRIMARY KEY (experience, goal)
);
```

`pattern` stays `text` and becomes derived rather than authoritative — the muscle set is what the generator reasons about.

---

## 12. Rollout

| Phase | Ships | Risk |
|---|---|---|
| **0 — stop the bleeding** | Fix `upper_lower`/`full_body` mapping to multi-pattern muscle sets | Low; contained to one `case` + the selection query |
| **1 — intake** | Add experience + environment to onboarding, backfill existing users | Low |
| **2 — catalog** | Import 619, enrich ~150 Core, keep 40 existing as Core | Medium; enrichment is the real cost |
| **3 — generator** | Volume-driven generation, goal-aware prescription | High; regenerates everyone's plan |
| **3.5 — shape transitions** | Continuity pass, volume ramp, kept/added/dropped diff (§8.3) | Medium; ships with Phase 3 or immediately after |
| **4 — progression** | Experience-tuned progression + deload | Medium |
| **5 — swap** | Swap UI + override persistence | Low |
| **6 — level transitions** | Promotion detector, coach proposal, `training_profiles` versioning (§8.1–8.2) | Medium; needs Phase 4's deload to exist first |
| **7 — program lifecycle** | Blocks, planned deloads, `programs.ends_on` (§8.4) | High; the long game |

Phase 0 is worth doing immediately and independently — it's a live bug behind a one-tap control.

**Ordering constraint:** Phase 6 depends on Phase 4, because "the stall survived a deload" is part of the promotion test and deload doesn't exist yet. Phase 3.5 should not lag Phase 3 by much — Phase 3 is precisely when everyone's plan gets rebuilt, so that's the moment continuity and the ramp matter most.

---

## 13. Decisions

The eight open questions from the first draft, resolved.

### 13.1 Rollout — lazy migration, never mid-week

Neither "auto-regenerate everyone" nor "prompt and wait." Both are wrong at the edges: the first rewrites a week someone has already organised their life around, the second strands users on logic we know is worse.

| User | Behaviour |
|---|---|
| New | New generator immediately |
| Existing, plan **actively broken** (the `upper_lower`/`full_body` users from §1) | **Force-rebuild, no prompt** — but only at a week boundary, and tell them after |
| Existing, plan fine | Keep running until a natural boundary, then offer: *"I've learned more about building your week. Want me to rebuild it?"* |

"Natural boundary" = the next time they change something that triggers a rebuild anyway, or a week boundary — never mid-week.

This needs a `generator_version` column on `programs` so we can tell who is on what and migrate in waves rather than one big-bang.

**Principle:** silently changing what someone has planned their week around is a trust violation. Silently leaving a *broken* plan in place is a worse one.

### 13.2 Core membership — derived from coverage, not taste

Don't hand-pick 150 exercises from intuition. Build a coverage matrix and let the list fall out of it:

**18 muscles × 3 environments × {compound, isolation}**, requiring **≥2 options per cell** (so swap always has somewhere to go) and **≥3 for the major movers** (chest, back, quads, hams, glutes, delts).

That mechanically produces ~120–160. Rank candidates within each cell by: *already in our 36* → compound → common equipment → beginner-accessible.

The existing 36 are **automatically Core** — they're already enriched *and* hand-illustrated. Review then only covers cells where the matrix picked something questionable, which is a few dozen judgement calls, not 150.

### 13.3 Images — keep ours, use theirs to fill the gap

To answer the question directly: they're **photographs of a person performing the lift** — two per exercise (start and end position), 850×567 JPEG, ~73KB. Coverage is **619/619** for the strength set, so every imported exercise has both.

**But don't replace what we have.** Our 36 exercises already have 100%-covered hand-made anatomical illustrations (`.webp`, with the worked muscles highlighted). Those teach *which muscle this trains* — a stock gym photo cannot. Swapping them for photos is a downgrade.

| Exercise set | Guide asset |
|---|---|
| Existing 36 (Core) | **Keep** the anatomical illustrations |
| ~580 newly imported | Dataset photos |
| Future Core promotions | Commission an illustration; photo until then |

Result: 100% guide coverage, best asset per exercise, nothing good thrown away.

> **Rights caveat — unresolved, blocking the mirror.** §13.3 judged these
> images on quality alone. The dataset repo carries The Unlicense, which covers
> the *compilation*; it does not clearly dedicate the underlying photographs,
> which are bodybuilding.com exercise-database shoots — and some frames carry a
> visible bodybuilding.com logo on the model's shirt (Reverse Flyes is one).
> The mirror is therefore **on hold**: the ten newly-promoted Core exercises
> keep the placeholder icon rather than ship third-party branded photos into a
> released app. Files are staged and the upload is minutes' work once this is
> settled. Resolving it means one of: confirming the licence covers the images,
> commissioning illustrations, or generating them.

**Mirror, don't hot-link.** 619 × 2 × ~73KB ≈ **90MB**, trivial against the progress-photo bucket, and converting to `.webp` (as our existing guides already are) will cut it substantially. Hot-linking makes our exercise guides break if someone renames a folder in a repo we don't control.

### 13.4 `general_health` is a signal, not a goal

It has no distinct prescription — there is no rep range that means "health," and inventing one would be fake precision.

Treat it as **"no strong preference"**: the fallback template (balanced, 8–15 reps, low end of the volume budget). When it's picked *alongside* other goals it contributes nothing and is ignored; the other goals lead. It stays in the UI because "I just want to train sensibly" is a real and common answer — it simply maps to a sensible default rather than its own row in the volume table.

### 13.5 Deload — build the mechanic, hide the word

Yes, it's needed: advanced training doesn't work without it, and §8.1's promotion test literally depends on "the stall survived a deload."

But **never show the user the word "deload."** It reads as the app making them go backwards. Present the *reason and the action*:

> Your bench has sat at 80 kg for three sessions. This week I'm dropping it about 10% so you can come back at it with something left in the tank.

Two rules:

- **Reactive first** (auto-trigger on a stall, Phase 4), **scheduled second** (planned block deloads, Phase 7). Reactive is easier to justify to a user because there's visible evidence.
- **Always skippable.** Forcing a light week on someone who feels great costs more trust than the deload gains.

### 13.6 Promotion cadence — evaluate on finish, notify at a boundary

**Evaluate on session finish.** The data just changed, the check is cheap, and it needs no cron.

**Notify separately from evaluating.** Never interrupt a session with a level-change proposal — surface it in the morning note or at the next session start. And **apply at a week boundary**, since a level change moves weekly volume.

**Re-asking after a decline:** don't re-ask on a fixed timer — re-ask when the *evidence strengthens* (a third lift stalls), capped at one proposal per 4 weeks. After two declines, stop asking for 12 weeks. A coach who keeps asking the same question is nagging, not coaching.

### 13.7 Never show the tier — describe the change instead

Agreed: the label stays internal. Three reasons it should never surface:

1. Self-selection is biased — offered the choice, most people pick "advanced," which is exactly the group that then can't recover from the volume.
2. "You are a beginner" is demotivating and, for someone six months in, insulting.
3. The label carries no information the user can act on.

So: **ask behaviourally, never by identity.** Onboarding already asks "how long have you trained consistently?" rather than "are you a beginner?" — keep that framing everywhere.

This also dissolves §8.1's awkwardness about intermediate → advanced needing consent. **Consent to the behaviour, not the tier:**

> I'd like to add a lighter week every fourth week and push your volume up a little. Want me to?

That's answerable. "Do you want to become advanced?" is not.

### 13.8 A declared pause is information; silence is not

They should absolutely behave differently — the difference is **how much we know**.

| | Declared pause | Silent absence |
|---|---|---|
| We know | Why, and how long | Nothing |
| Consistency metric | Already excluded | Excluded retroactively |
| Threshold | The actual pause length | **3 weeks** (cautious, since we're guessing) |
| On return | Deterministic ramp from pause length, loads kept, no questions | **Ask one question** |
| Tone | *"Welcome back — picking up where you left off."* | *"Good to see you. Pick up where you left off, or ease in?"* |

We use 3 weeks for silence rather than §8.1's 6 because meaningful detraining starts around 3–4 weeks and, absent information, the cautious default is better. A user who was actually fine just taps "pick up where I left off."

The reward for using the pause feature is that we never ask — which is a real incentive to use it.

---

## 14. Still open

- **Guide illustration pipeline.** §13.3 keeps illustrations for Core, but there's no process for producing new ones as exercises get promoted. Commission, generate, or accept photos indefinitely?
- **Volume-table tuning.** The numbers in §6 are defensible starting points, not measured. Once Progress has real per-muscle data across users, they should be revisited.

### Known limitation shipped in Phase 0 — Plan 03 must close it

Phase 0 (migration `v2_0021`, applied) fixed **pattern-level** completeness: every split now trains push, pull and legs. It did **not** fix **muscle-level** completeness, and the gap is deterministic rather than occasional.

On a multi-pattern day more muscles compete than there are slots — an Upper day has 8 primary muscles for 6 slots. Selection still orders by `default_rep_low, slug` (inherited from the one-pattern-per-day era, where 4 muscles always fit 4 slots and nothing was ever discarded). Small muscles carry the highest rep ranges, so they lose every time. Verified against the live catalog:

| Split · day | Muscles vs slots | Dropped every time |
|---|---|---|
| `upper_lower` · Upper | 8 vs 6 | Side Delt (`lateral-raise`, rep_low 12), Rear Delt (`face-pull`, rep_low 15) |
| `full_body` · A (push,legs) | 8 vs 6 | Side Delt, Calves |
| `full_body` · B (pull,legs) | 8 vs 6 | Rear Delt, Calves |
| `push_pull_legs` · any | 4 vs 4 | none — nothing is ever discarded |

This was left in place deliberately. It is a strict improvement on what it replaced (`upper_lower` previously had *no* pull work at all), and the two cheap fixes are both wrong: reordering would change the *ordinal*, which drives `sets_target` and `rest_seconds`, silently rewriting every existing PPL user's prescription; and raising the slot cap to 8 contradicts §6's 4–6 session-length cap.

**CLOSED by `v2_0029` (applied).** Selection is now driven by a weekly
per-muscle set budget. The acceptance test
`supabase/tests/v2_0029_volume_coverage_test.sql` asserts that Side Delt, Rear
Delt, Calves **and Abs** receive weekly volume under all three splits, and it
passes. Two further defects surfaced while closing this one: no split included
the `core` pattern, so Abs were never trained at all; and `upper_lower` emitted
one `program_day` per day-*type*, so a 4-day user got the same two sessions
twice. Both are fixed in the same migration.

Original reasoning, kept for the record:

**Plan 03 closes it by construction.** Once selection is driven by a weekly per-muscle set budget (§6.1–6.3) rather than a per-session slot race, a muscle earns its sets across the week instead of competing for a seat in one session. Treat "side delt, rear delt and calves receive their weekly volume target under every split" as an acceptance criterion for Plan 03.
