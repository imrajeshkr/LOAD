# Session Flow — Remove the Start Gate (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the lift screen behave like a workout rather than a form — every set prefilled and editable on arrival, each set logged by its own circle, and the exercise changed by pulling the next one up.

**Architecture:** The screen's blocking flaw is a *start gate*: `_sets[idx]` is empty until "Start this lift", and a single shared staging slot (`_stagedKg`/`_stagedReps`) means only the next row can hold a value. Task 1 replaces that slot with a per-row model (`PlannedSets`), which is what makes every other change possible. UI tasks follow, then the ribbon, then the overscroll pager last because it is the only non-stock interaction here.

**Tech Stack:** Flutter 3 (Dart 3 records + pattern matching), `ChangeNotifier` state, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-08-29-session-flow-and-exercise-control-design.md`

**Scope note:** The spec covers two independent subsystems. This plan is Project A only. Project B (replace / add / custom exercises) gets its own plan, written after this one lands so it can build on what actually shipped rather than on what was predicted.

## Global Constraints

- Every tappable in `lib/screens/**` uses `Pressable` from `lib/widgets/pressable.dart` — never a raw `GestureDetector(onTap:)` or `InkWell`. Genuine non-tap gestures (pan, drag, scale) may use a raw `GestureDetector` with `// interactivity-ok` on that line. Enforced by `./tool/check_interactivity.sh`.
- Haptic tiers: `PressFx.light` = chips/rows/toggles · `PressFx.medium` = primary CTA · `PressFx.strong` = big/destructive · `PressFx.none` = handler already buzzes.
- `flutter analyze lib` must report **no errors and no warnings**. Four pre-existing `info`s are acceptable; do not add a fifth.
- `flutter test` must pass.
- Do not change `lib/screens/{today,chat,settings,onboarding}` or `app_shell.dart` — dead v1 code.
- Copy rule from the spec: Skip and "Do it later" stay **visible**, never behind an overflow menu.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `lib/services/planned_sets.dart` (new) | Pure, dependency-free model of the editable rows a lifter sees before logging. No Flutter, no Supabase — unit-testable in isolation. | 1 |
| `test/services/planned_sets_test.dart` (new) | Unit tests for the above. | 1 |
| `lib/services/session_controller.dart` | Swaps the single staging slot for `PlannedSets`; gains `unlogFrom`. | 1, 2 |
| `lib/screens/v2/session_flow_screen.dart` | `_SetChip` rows become live and self-logging; `_BottomBar` becomes Done + links; `_Rail` scrolls; `_LiftScreen` gains the pager. | 2–5 |
| `lib/widgets/overscroll_pager.dart` (new) | The elastic pull-to-next-exercise widget, isolated so its physics can be reasoned about and replaced without touching the lift screen. | 5 |

---

## Task 1: Per-row staged values

The single `_stagedKg`/`_stagedReps` pair can only describe *the next* set. The spec requires every row prefilled and adjustable, so the model has to hold one value per row.

**Files:**
- Create: `lib/services/planned_sets.dart`
- Create: `test/services/planned_sets_test.dart`
- Modify: `lib/services/session_controller.dart`

**Interfaces:**
- Produces: `PlannedSets.seed({required int count, required double kg, required int reps})`, `int get length`, `(double, int) at(int n)`, `void adjust(int n, {double dKg, int dReps})`, `void grow(int count)`.
- Produces on the controller: `PlannedSets planned` (getter for the current exercise), `void adjustPlanned(int n, {double dKg, int dReps})`.

- [ ] **Step 1: Write the failing test**

```dart
// test/services/planned_sets_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:load_app/services/planned_sets.dart';

void main() {
  test('seeds every row with the same prefill', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    expect(p.length, 3);
    expect(p.at(0), (60.0, 8));
    expect(p.at(2), (60.0, 8));
  });

  test('adjusting one row leaves the others alone', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    p.adjust(1, dKg: -5, dReps: 2);
    expect(p.at(0), (60.0, 8));
    expect(p.at(1), (55.0, 10));
    expect(p.at(2), (60.0, 8));
  });

  test('weight never goes negative and reps never go below one', () {
    final p = PlannedSets.seed(count: 1, kg: 2.5, reps: 1);
    p.adjust(0, dKg: -10, dReps: -5);
    expect(p.at(0), (0.0, 1));
  });

  test('grow adds rows carrying the last row values', () {
    final p = PlannedSets.seed(count: 2, kg: 60, reps: 8);
    p.adjust(1, dKg: 5);
    p.grow(4);
    expect(p.length, 4);
    expect(p.at(2), (65.0, 8));
    expect(p.at(3), (65.0, 8));
  });

  test('grow never shrinks', () {
    final p = PlannedSets.seed(count: 3, kg: 60, reps: 8);
    p.grow(2);
    expect(p.length, 3);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/services/planned_sets_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:load_app/services/planned_sets.dart'`

> If the package name is not `load_app`, read `name:` from `pubspec.yaml` and use that in the import.

- [ ] **Step 3: Write the model**

```dart
// lib/services/planned_sets.dart

/// The rows a lifter sees for one exercise before any of them are logged.
///
/// Exists because the session used to keep a single staged weight/reps pair,
/// which can only ever describe the NEXT set. The screen now shows every set
/// prefilled and individually adjustable, so each row needs its own value.
///
/// Deliberately free of Flutter and Supabase so it can be tested on its own.
class PlannedSets {
  final List<double> _kg;
  final List<int> _reps;

  PlannedSets.seed({required int count, required double kg, required int reps})
      : _kg = List<double>.filled(count, kg, growable: true),
        _reps = List<int>.filled(count, reps, growable: true);

  int get length => _kg.length;

  (double, int) at(int n) => (_kg[n], _reps[n]);

  /// Nudge one row. Weight floors at 0 (an empty bar is a real answer) and
  /// reps floor at 1 (a logged set with zero reps is not a set).
  void adjust(int n, {double dKg = 0, int dReps = 0}) {
    if (n < 0 || n >= _kg.length) return;
    _kg[n] = (_kg[n] + dKg).clamp(0, 999);
    _reps[n] = (_reps[n] + dReps).clamp(1, 100);
  }

  /// Extend to [count] rows, carrying the last row's values forward — a lifter
  /// adding a fourth set almost always wants what they just did.
  void grow(int count) {
    while (_kg.length < count) {
      _kg.add(_kg.isEmpty ? 0 : _kg.last);
      _reps.add(_reps.isEmpty ? 1 : _reps.last);
    }
  }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `flutter test test/services/planned_sets_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Wire it into the controller**

In `lib/services/session_controller.dart`:

Add the import at the top with the other `services/` imports:

```dart
import 'planned_sets.dart';
```

Add the field beside `late List<List<SetRow>> _sets;`:

```dart
  /// One editable row set per exercise, seeded on first view.
  late List<PlannedSets?> _planned;
```

In the same constructor body that runs `_sets = ...` and `_skipped = List.filled(exercises.length, false);`, add:

```dart
    _planned = List<PlannedSets?>.filled(exercises.length, null);
```

Add these members next to `staged()`:

```dart
  /// The editable rows for the current exercise, seeded on first access from
  /// the same prefill `staged()` used to compute for the next set alone.
  PlannedSets get planned {
    final existing = _planned[idx];
    if (existing != null) {
      existing.grow(target(idx));
      return existing;
    }
    final e = ex;
    final seeded = PlannedSets.seed(
      count: target(idx),
      kg: planKg(idx),
      reps: e.prefillReps,
    );
    _planned[idx] = seeded;
    return seeded;
  }

  void adjustPlanned(int n, {double dKg = 0, int dReps = 0}) {
    planned.adjust(n, dKg: dKg, dReps: dReps);
    notifyListeners();
  }
```

- [ ] **Step 6: Verify nothing broke**

Run: `flutter analyze lib && flutter test`
Expected: analyze reports no errors/warnings (4 pre-existing infos are fine); all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/services/planned_sets.dart test/services/planned_sets_test.dart lib/services/session_controller.dart
git commit -m "feat(session): per-row staged values

A single staged weight/reps pair can only describe the next set, which is
why every row after it rendered inert. PlannedSets holds one value per row
so the whole table can be prefilled and adjusted before anything is logged.

Kept free of Flutter and Supabase so it is testable on its own."
```

---

## Task 2: Log and un-log from the row itself

**Files:**
- Modify: `lib/services/session_controller.dart`
- Modify: `lib/screens/v2/session_flow_screen.dart:691` (`_SetChip`)

**Interfaces:**
- Consumes: `PlannedSets`, `controller.planned`, `controller.adjustPlanned` from Task 1.
- Produces: `Future<void> logRow(int n)`, `Future<void> unlogFrom(int n)`.

Sets are physically sequential, so row *n* is loggable only when `n == sets.length`. Tapping a logged row's circle un-logs from there down. That makes the circle a toggle, which the spec requires: removing the start gate means a mis-tap writes a set, and it must be reversible in place.

- [ ] **Step 1: Replace `logSet()`'s staging read with the row's own values**

In `lib/services/session_controller.dart`, change the first lines of `logSet()`:

```dart
  Future<void> logSet() async {
    final e = ex;
    final st = staged();
    _sets[idx].add(SetRow(e.isBodyweight ? null : st.$1, st.$2));
```

to:

```dart
  Future<void> logSet() async {
    final e = ex;
    final n = _sets[idx].length;
    final st = planned.at(n);
    _sets[idx].add(SetRow(e.isBodyweight ? null : st.$1, st.$2));
```

Leave the rest of `logSet()` unchanged, but delete the two now-dead lines:

```dart
    _stagedKg = null;
    _stagedReps = null;
```

- [ ] **Step 2: Add the row-addressed entry points**

Add beside `logSet()`:

```dart
  /// Log row [n]. Only the next un-logged row is loggable — sets happen in
  /// order, and letting row 3 be logged before row 1 would record a session
  /// that never happened.
  Future<void> logRow(int n) async {
    if (n != _sets[idx].length) return;
    await logSet();
  }

  /// Un-log row [n] and everything after it. The log circle is a toggle
  /// because removing the start gate means a mis-tap writes a set.
  Future<void> unlogFrom(int n) async {
    final done = _sets[idx];
    if (n < 0 || n >= done.length) return;
    done.removeRange(n, done.length);
    _stopRest();
    askFeel = false;
    Haptics.tap();
    await _persist();
    notifyListeners();
  }
```

- [ ] **Step 3: Make every row live in the UI**

In `lib/screens/v2/session_flow_screen.dart`, inside `_SetChip.build`, replace:

```dart
    final editable = done || isNext;
```

with:

```dart
    // Every row is adjustable, logged or not. The start gate is gone, so there
    // is no such thing as a row you are not allowed to touch yet.
    const editable = true;
```

Replace the value read:

```dart
    double kg;
    int reps;
    if (done) {
      kg = c.sets[n].kg ?? 0;
      reps = c.sets[n].reps;
    } else {
      final s = c.staged();
      kg = s.$1;
      reps = s.$2;
    }
```

with:

```dart
    final double kg;
    final int reps;
    if (done) {
      kg = c.sets[n].kg ?? 0;
      reps = c.sets[n].reps;
    } else {
      final s = c.planned.at(n);
      kg = s.$1;
      reps = s.$2;
    }
```

Replace the stepper callbacks so an un-logged row edits its own planned values:

```dart
                  onDown: () => done ? c.adjustSet(n, dKg: -e.step) : c.adjustStagedWeight(-e.step),
                  onUp: () => done ? c.adjustSet(n, dKg: e.step) : c.adjustStagedWeight(e.step),
```

with:

```dart
                  onDown: () => done
                      ? c.adjustSet(n, dKg: -e.step)
                      : c.adjustPlanned(n, dKg: -e.step),
                  onUp: () => done
                      ? c.adjustSet(n, dKg: e.step)
                      : c.adjustPlanned(n, dKg: e.step),
```

Apply the same `done ? c.adjustSet(n, dReps: ±1) : c.adjustPlanned(n, dReps: ±1)` treatment to the reps `_Stepper` immediately below it.

- [ ] **Step 4: Make the circle the log control**

Still in `_SetChip.build`, the 22×22 `Container` holding the check/number becomes a `Pressable`. Replace the whole `Container(width: 22, height: 22, ...)` with:

```dart
          Pressable(
            haptic: PressFx.none, // logRow/unlogFrom buzz themselves
            onTap: done
                ? () => c.unlogFrom(n)
                : (n == c.sets.length ? () => c.logRow(n) : null),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: done ? AppColors.accent : AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: done
                      ? AppColors.accent
                      : (n == c.sets.length ? AppColors.accent : AppColors.borderFaint),
                  width: 1.5,
                ),
              ),
              child: done
                  ? const Icon(Icons.check_rounded, size: 15, color: AppColors.onAccent)
                  : Text('${n + 1}',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          color: n == c.sets.length
                              ? AppColors.accent
                              : AppColors.textFaint)),
            ),
          ),
```

The ring is accented on the next row so it reads as the thing to tap, plain on rows further out.

- [ ] **Step 5: Drop `isNext`, which was a gate artefact**

`_SetTable` computes `isNext` as `n == c.sets.length && c.entry == EntryModeV2.live`.
`entry` is null until `startLive` runs — the gate being removed — so under the
new model that expression is false for every row before the first log.

In `_SetTable.build`, change:

```dart
      final isNext = n == c.sets.length && c.entry == EntryModeV2.live;
```

to:

```dart
      // No `entry` check: that was true only after "Start this lift", which no
      // longer exists. The next row is simply the first un-logged one.
      final isNext = n == c.sets.length;
```

`_SetChip` keeps taking `isNext` and uses it only for the accent ring and
background — logging is driven by `n == c.sets.length` directly, as written in
Step 4.

- [ ] **Step 6: Verify**

Run: `flutter analyze lib && flutter test && ./tool/check_interactivity.sh`
Expected: no errors/warnings, tests pass, interactivity guard passes.

- [ ] **Step 7: Commit**

```bash
git add lib/services/session_controller.dart lib/screens/v2/session_flow_screen.dart
git commit -m "feat(session): log a set from its own row, and un-log it

Every row is now adjustable whether or not it is logged, and the circle on
each row logs it. Only the next un-logged row can be logged — sets happen in
order — and tapping a logged row un-logs from there down.

The toggle is not a nicety: without the start gate a mis-tap writes a set,
so it has to be reversible in place."
```

---

## Task 3: Cues hidden, except the first time

**Files:**
- Modify: `lib/services/session_controller.dart:93` and the `jump()` body around line 212

**Interfaces:**
- Consumes: nothing new.
- Produces: no new public members; `cuesOpen` changes its default only.

- [ ] **Step 1: Change the initial value**

In `lib/services/session_controller.dart`, change:

```dart
  bool cuesOpen = true;
```

to:

```dart
  /// Hidden by default: the set table is the point of this screen, and cues
  /// pushed it below the fold. Opened once for a lift the user has never done
  /// — hiding form cues from someone who has never squatted is withholding,
  /// not decluttering. See `_openCuesIfFirstTime`.
  bool cuesOpen = false;
```

- [ ] **Step 2: Replace the jump behaviour**

In `jump()`, change:

```dart
    cuesOpen = _sets[idx].isEmpty;
```

to:

```dart
    _openCuesIfFirstTime();
```

and add the helper beside `jump()`:

```dart
  /// A lift with no previous-session history is one this lifter has never
  /// done. Show them how, once.
  void _openCuesIfFirstTime() {
    cuesOpen = ex.lastSets.isEmpty && ex.cues.isNotEmpty;
  }
```

- [ ] **Step 3: Apply the same rule on first load**

In the constructor body, immediately after the line that sets `idx = foundIncomplete ? firstIncomplete : 0;`, add:

```dart
    _openCuesIfFirstTime();
```

- [ ] **Step 4: Verify**

Run: `flutter analyze lib && flutter test`
Expected: no errors/warnings; tests pass.

Manual check on the simulator: open a session for a lift with history — cues collapsed, "How to" visible. The demo account `rkumarmeena064@gmail.com` has seven months of history, so every lift there should land collapsed.

- [ ] **Step 5: Commit**

```bash
git add lib/services/session_controller.dart
git commit -m "feat(session): cues hidden by default

The set table is the point of this screen and cues were pushing it below
the fold. They now start collapsed, with one exception: a lift the user has
no history for opens them once. Hiding form cues from someone who has never
squatted is withholding, not decluttering."
```

---

## Task 4: Done, with Skip and Do it later demoted

**Files:**
- Modify: `lib/screens/v2/session_flow_screen.dart:971` (`_BottomBar`)
- Modify: `lib/screens/v2/session_flow_screen.dart:621` (`_SetTable`, for "Log the rest")

**Interfaces:**
- Consumes: `controller.sets`, `controller.advance()`, `controller.skipLift()`, `controller.deferLift()`, `controller.fillRemaining()`, `controller.hasOtherOpenLift`, `controller.resting`.
- Produces: nothing new.

Read `_BottomBar` before editing. It is **not** one button — it is a four-branch
state machine keyed on `c.entry` and `c.exDone`:

| Branch | Primary | Secondaries |
|---|---|---|
| `entry == null && sets.isEmpty` | Start this lift → `startLive` | Skip · Log at the end |
| `exDone` | Next lift / Finish session → `advance` | — |
| `entry == live && !resting` | Log set N → `logSet` | Done all sets · Log at the end |
| `entry == deferred` | Next lift / Finish session → `advance` | — |

Removing the start gate collapses the first and third branches: rows log
themselves now, so neither "Start this lift" nor "Log set N" has a job. There is
**no `finishLift` method** — completion is `c.advance`.

**"Done all sets" must survive.** With per-row logging, three sets is three taps
where `fillRemaining` was one. Dropping it would be a regression, so it moves to
the set table, which is where set-level actions belong — the bottom bar keeps
lift-level ones. That is also what keeps the secondary line to the two the spec
asks for.

- [ ] **Step 1: Move "Log the rest" into the set table**

In `_SetTable.build`, the bottom row currently holds `Target ...` and
`+ add a set`. Add the fill action between them, shown only when rows remain:

```dart
              Text('Target ${e.prescription}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.inactiveFill)),
              Row(children: [
                // Was "Done all sets" in the bottom bar. Per-row logging makes
                // three sets three taps, so this shortcut has to stay — it just
                // belongs with the sets rather than with the lift.
                if (c.sets.length < target0(c))
                  Pressable(
                    haptic: PressFx.light,
                    onTap: c.fillRemaining,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 14),
                      child: Text('log the rest',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 11,
                              color: AppColors.textDim)),
                    ),
                  ),
                Pressable(
                  onTap: c.addSet,
                  child: const Text('+ add a set',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textDim)),
                ),
              ]),
```

- [ ] **Step 2: Collapse the bar to two branches**

Replace the whole `Column` body of `_BottomBar.build` with:

```dart
        children: [
          if (c.resting) _RestBar(c: c),
          if (c.exDone || c.entry == EntryModeV2.deferred)
            _PrimaryBtn(
              label: c.hasOtherOpenLift ? 'Next lift' : 'Finish session',
              onTap: c.advance,
            )
          else ...[
            _PrimaryBtn(
              // Zero sets is not "done", it is "skipped" — and Skip is right
              // there. Done never invents sets; "log the rest" does that, and
              // lives with the set table.
              label: 'Done',
              onTap: c.sets.isEmpty ? null : c.advance,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Pressable(
                  haptic: PressFx.light,
                  onTap: c.deferLift,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('Do it later',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 12,
                            color: AppColors.textMuted)),
                  ),
                ),
                const Text('·',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12,
                        color: AppColors.textFaint)),
                Pressable(
                  haptic: PressFx.strong, // dropping a lift is the destructive one
                  onTap: c.skipLift,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('Skip',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 12,
                            color: AppColors.textMuted)),
                  ),
                ),
              ],
            ),
          ],
        ],
```

- [ ] **Step 3: Let the primary button be disabled**

`_PrimaryBtn` currently takes a non-null `VoidCallback`. Widen it and grey the
fill when it is null:

```dart
  final VoidCallback? onTap;
```

and in its `build`, wherever the fill colour is set:

```dart
      color: onTap == null ? AppColors.inactiveFill : AppColors.accent,
```

- [ ] **Step 4: Retire `startLive`**

Nothing calls `c.startLive` any more. Leave the method in place but mark it so
the next reader is not confused:

```dart
  /// Unused since the start gate was removed — rows log themselves. Kept only
  /// because the v1 session screen still references it.
  void startLive() {
```

Run `grep -rn "startLive" lib/` and confirm the only remaining references are
the definition and `lib/screens/today/` (dead v1 code, out of scope).

- [ ] **Step 5: Verify**

Run: `flutter analyze lib && flutter test && ./tool/check_interactivity.sh`
Expected: no errors/warnings; tests pass; guard passes.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/v2/session_flow_screen.dart lib/services/session_controller.dart
git commit -m "feat(session): Done replaces Start, Skip and Do it later demoted

The bottom bar was a four-branch state machine whose first and third branches
existed only to run the start gate. Rows log themselves now, so neither
'Start this lift' nor 'Log set N' has a job, and the bar collapses to Done
plus one lighter line.

Done is disabled until a set is logged, because zero sets is not done — it is
skipped, and Skip is right there. It never invents sets either: 'log the rest'
does that, and moved to the set table where set-level actions belong.

Skip and Log-at-the-end were two identical buttons competing with the primary
action, which is why they read as twins. Both stay visible: 'the rack is busy'
is a mid-session frustration and burying it in a menu means nobody finds it."
```

---

## Task 5: A ribbon that scrolls and follows

**Files:**
- Modify: `lib/screens/v2/session_flow_screen.dart:133` (`_Rail`)

**Interfaces:**
- Consumes: `controller.order`, `controller.idx`.
- Produces: nothing new.

`_Rail` is a `Row` of `Expanded`, so items are squeezed and names truncate (`STANDING DUMBBE…` with only four lifts). It must scroll, and it must bring the active lift into view as the session advances.

- [ ] **Step 1: Make `_Rail` stateful and scrollable**

Replace the whole `_Rail` class with:

```dart
class _Rail extends StatefulWidget {
  final SessionController c;
  const _Rail({required this.c});
  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int? _lastIdx;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Bring the active lift into view whenever it changes, so progressing
  /// through the session scrolls the ribbon on its own.
  void _followActive() {
    if (_lastIdx == widget.c.idx) return;
    _lastIdx = widget.c.idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _keys[widget.c.idx];
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _followActive();
    final order = widget.c.order;
    return SizedBox(
      height: 34,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        itemCount: order.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, k) {
          final exIdx = order[k];
          final key = _keys.putIfAbsent(exIdx, GlobalKey.new);
          // Sized to its own label rather than an equal share of the row:
          // four lifts used to truncate to "STANDING DUMBBE…".
          return KeyedSubtree(
            key: key,
            child: _RailItem(c: widget.c, exIdx: exIdx),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 2: Let the item size itself**

Open `_RailItem.build`. If its root sizes to `double.infinity` or is wrapped so it fills, remove that so the item is as wide as its text plus padding. The label `Text` must **not** have `overflow: TextOverflow.ellipsis` with a fixed width — the point of scrolling is that names are readable in full.

- [ ] **Step 3: Verify**

Run: `flutter analyze lib && flutter test && ./tool/check_interactivity.sh`
Expected: clean.

Manual check: start a session with 5+ lifts on the demo account. Names read in full; the ribbon scrolls; logging through a lift and advancing scrolls the next one into view without a tap.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/v2/session_flow_screen.dart
git commit -m "feat(session): the exercise ribbon scrolls and follows you

It was a Row of Expanded, so lifts were squeezed to an equal share and names
truncated at four exercises. It now scrolls horizontally with each item sized
to its label, and animates the active lift into view on every jump — so
progressing through the session moves the ribbon without a tap."
```

---

## Task 6: Pull the next exercise up

**Files:**
- Create: `lib/widgets/overscroll_pager.dart`
- Modify: `lib/screens/v2/session_flow_screen.dart:46` (`_LiftScreen`)

**Interfaces:**
- Consumes: `controller.order`, `controller.idx`, `controller.jump(int)`.
- Produces: `OverscrollPager({required int index, required int count, required IndexedWidgetBuilder builder, required ValueChanged<int> onPage})`.

**This is the only non-stock interaction in the plan and is scheduled last so nothing else waits on it.** Simulator scrolling has no thumb momentum — it must be checked on a real device before being called done.

The lift body already scrolls vertically, so a vertical pager and the content would fight over the same gesture. Driving the page change from *overscroll* resolves that: scroll normally inside a lift; at the bottom, keep dragging and the next lift rises behind it, tracking the finger; release past a threshold to snap, release short to spring back.

- [ ] **Step 1: Build the pager**

```dart
// lib/widgets/overscroll_pager.dart
import 'package:flutter/material.dart';

/// Pages vertically, but only once the child's own scroll has run out.
///
/// The lift screen scrolls vertically inside each page, so a plain vertical
/// PageView would compete with it for the same drag. Listening to overscroll
/// instead means the gesture is continuous: scroll to the bottom of a lift,
/// keep pulling, and the next one rises behind it. Release past
/// [snapFraction] of the viewport and it takes over; release short and it
/// springs back, so a lifter can see what is coming and change their mind.
class OverscrollPager extends StatefulWidget {
  final int index;
  final int count;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onPage;
  final double snapFraction;

  const OverscrollPager({
    super.key,
    required this.index,
    required this.count,
    required this.builder,
    required this.onPage,
    this.snapFraction = 0.35,
  });

  @override
  State<OverscrollPager> createState() => _OverscrollPagerState();
}

class _OverscrollPagerState extends State<OverscrollPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(() => setState(() {}));

  /// Signed drag in logical pixels. Positive = pulling the NEXT lift up.
  double _drag = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  bool get _canNext => widget.index < widget.count - 1;
  bool get _canPrev => widget.index > 0;

  double get _offset =>
      _anim.isAnimating ? _drag * (1 - _anim.value) : _drag;

  void _settle(double height) {
    final threshold = height * widget.snapFraction;
    final goNext = _drag > threshold && _canNext;
    final goPrev = _drag < -threshold && _canPrev;

    if (goNext || goPrev) {
      widget.onPage(widget.index + (goNext ? 1 : -1));
      _drag = 0;
      _anim.value = 0;
      setState(() {});
      return;
    }
    // Short of the threshold: spring back, nothing changed.
    _anim.forward(from: 0).whenComplete(() {
      _drag = 0;
      _anim.value = 0;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        final o = _offset.clamp(-h, h);
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is OverscrollNotification) {
              final pulling = n.overscroll > 0 ? _canNext : _canPrev;
              if (pulling) {
                // Damped so the pull feels elastic rather than 1:1.
                setState(() => _drag += n.overscroll * 0.5);
              }
            } else if (n is ScrollEndNotification && _drag != 0) {
              _settle(h);
            }
            return false;
          },
          child: Stack(
            children: [
              Transform.translate(
                offset: Offset(0, -o),
                child: widget.builder(context, widget.index),
              ),
              if (o > 0 && _canNext)
                Transform.translate(
                  offset: Offset(0, h - o),
                  child: SizedBox(
                    height: h,
                    child: widget.builder(context, widget.index + 1),
                  ),
                ),
              if (o < 0 && _canPrev)
                Transform.translate(
                  offset: Offset(0, -h - o),
                  child: SizedBox(
                    height: h,
                    child: widget.builder(context, widget.index - 1),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 2: Wrap the lift body**

In `_LiftScreen.build`, the `Expanded(child: ListView(...))` holding `_ExerciseHead` through `_ExDoneCard` becomes the pager's page. Keep `_Header` and `_Rail` above it and `_BottomBar` below it — they must not move with the page.

```dart
          Expanded(
            child: OverscrollPager(
              index: c.order.indexOf(c.idx),
              count: c.order.length,
              onPage: (k) => c.jump(c.order[k]),
              builder: (_, k) => _LiftBody(c: c, exIdx: c.order[k]),
            ),
          ),
```

Extract the existing `ListView` into a `_LiftBody` widget taking `exIdx`, so the pager can build the neighbouring lift as well as the current one. Its `ListView` must keep `physics: const AlwaysScrollableScrollPhysics()` so overscroll notifications fire even when the content is shorter than the viewport.

Add the import:

```dart
import '../../widgets/overscroll_pager.dart';
```

- [ ] **Step 3: Verify it compiles and nothing regressed**

Run: `flutter analyze lib && flutter test && ./tool/check_interactivity.sh`
Expected: clean. The pager uses `NotificationListener`, not a raw `GestureDetector`, so the interactivity guard has nothing to object to.

- [ ] **Step 4: Check it on a real device, not the simulator**

Build and run on a physical iPhone. Confirm:
1. Scrolling within a lift feels unchanged.
2. At the bottom, continuing to drag raises the next lift, tracking the finger.
3. Releasing past roughly a third of the screen snaps to it; releasing short springs back with nothing changed.
4. The same works downward for the previous lift.
5. The ribbon follows on both.

Simulator scrolling has no thumb momentum, so a simulator pass is not evidence here. If it feels wrong, tune `snapFraction` and the `0.5` damping factor — those two numbers are the whole feel.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/overscroll_pager.dart lib/screens/v2/session_flow_screen.dart
git commit -m "feat(session): pull the next exercise up

The lift body scrolls vertically, so a vertical pager would have fought the
content for the same drag. Driving the page from overscroll resolves that
rather than working around it: scroll to the bottom of a lift, keep pulling,
and the next rises behind it tracking the finger. Release past a third of
the screen to snap, release short to spring back.

The gesture is continuous and reversible, so a lifter can see the next lift
arriving and change their mind — a discrete swipe cannot do that.

Isolated in its own widget: it is custom physics, and snapFraction plus the
damping factor are the entire feel, so they should be tunable without
touching the lift screen."
```

---

## Manual acceptance

After Task 6, on the demo account `rkumarmeena064@gmail.com`:

1. Start a session. Every set row shows a weight and reps immediately — no "Start this lift".
2. Adjust set 3's weight before logging set 1. Set 1 and 2 are unchanged.
3. Tap set 1's circle. It fills; the rest timer starts.
4. Tap it again. It un-logs, and the timer stops.
5. "Done" is grey until a set is logged.
6. Cues are collapsed on a lift with history.
7. The ribbon scrolls, shows full names, and follows as lifts complete.
8. Pull up past the bottom of a lift — the next one rises and snaps.
