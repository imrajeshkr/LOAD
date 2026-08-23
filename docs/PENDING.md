# Pending

Things known to be unfinished, and why. Kept short and honest — if an item
here is vague or has no owner, it is not a real item.

The exercise plan builder itself (spec
`docs/superpowers/specs/2026-08-23-exercise-plan-builder-design.md`, plans
01–07) is fully implemented and applied.

---

## Blocked on a decision, not on work

### Guide images for 494 Extended exercises

Every Core exercise the generator can prescribe has an illustration. The
imported catalog — the pool exercise **swap** draws from — mostly does not, so
the swap sheet is a metadata list rather than a thumbnail grid.

Three options, none of them technical:

| Option | Cost | Problem |
|---|---|---|
| Ship the dataset photos | free, 100% coverage | Licence unresolved — see below |
| CC-BY-SA line art | free, ~28/494 coverage | Style clashes with our anatomical illustrations; attribution + ShareAlike obligations |
| Commission / generate | money or time | Only sane at Core scale (~46), not 530 |

**On the dataset photos.** `yuhonas/free-exercise-db` carries The Unlicense,
which covers the *compilation*. The images are bodybuilding.com exercise-database
shoots and some carry a visible logo on the model's shirt.
[Issue #2](https://github.com/yuhonas/free-exercise-db/issues/2) asked the
maintainer directly about image rights in June 2023 and was **closed with no
answer**. That is why they are not shipped. Files are staged; the upload is
minutes once someone decides.

**Recommendation:** leave Extended without images, commission ~10 illustrations
for the Core exercises that lack them. That is the set users are actually
prescribed.

### Illustration pipeline (spec §14)

No process exists for producing an illustration when an exercise is promoted to
Core. Same decision as above, asked prospectively. Currently: promoted lifts
show the placeholder.

---

## Cannot be solved with more of our own output

### Volume-table tuning (spec §6, §14)

The sets-per-muscle-per-week numbers (beginner 9 · intermediate 14 · advanced
18, modified by goal) are defensible starting points taken from common
practice. **They have not been measured.**

**Synthetic data cannot fix this, and it is worth being explicit about why.**
Generating training histories requires assuming a dose–response model — how
much someone gains from a given weekly volume. Tuning the table against data
produced by that assumption recovers the assumption, not the truth. The output
would be a confident-looking number with nothing behind it, which is *worse*
than an admitted guess because it stops the question being asked.

What synthetic data legitimately covers is structural soundness, and that is
already done: `supabase/tests/v2_matrix_sweep.sql` proves every plan *shape* is
coherent. That is a different claim from the volumes being *right*.

**Unblocked by:** real training logs across real users, or a literature review
against published volume-response work. Neither is available yet.

---

## Small, and ours whenever wanted

### Swap has no undo in the UI

`unswap_exercise()` exists, is tested, and reverses both the standing
preference and the live plan. It was never surfaced. A lifter who swaps into
something they dislike currently has to swap back manually, and cannot restore
the original if they no longer remember what it was.

Likeliest thing to frustrate someone who has used swap.

### `flutter analyze` carries 4 pre-existing infos

Two `curly_braces_in_flow_control_structures`, one
`use_build_context_synchronously`, one other. CI deliberately fails on errors
and warnings but not infos, so that a red-from-day-one pipeline does not train
people to ignore it. Worth clearing so the threshold can be tightened.

---

## Resolved — kept as a record of what the answer was

- **`LOAD_SUPABASE_DB_PASSWORD` CI secret** — set 2026-08-23. The SQL suites
  and the nightly generator sweep now actually run instead of reporting a green
  check that verified nothing.
