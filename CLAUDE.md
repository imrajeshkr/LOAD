# Project conventions

## Button interactivity (required)

Every tappable in the app must feel pressed: a quick press-scale + a haptic
tuned to the action's weight. There is one primitive for this —
[`lib/widgets/pressable.dart`](lib/widgets/pressable.dart).

**Rule:** in `lib/screens/**` use `Pressable` for taps, never a raw
`GestureDetector(onTap:)` or `InkWell`.

```dart
Pressable(
  haptic: PressFx.medium,      // light = chips/rows/toggles · medium = primary CTA · strong = big/destructive · none = handler already buzzes
  onTap: _doThing,
  child: <your button visual>,
)
```

- Material buttons (`ElevatedButton`/`TextButton`/`OutlinedButton`) already show
  a ripple; if you must use one, add a `Haptics.*` call in its `onPressed`.
- Genuine non-tap gestures (pan, scale, custom drag, `LongPressDraggable`,
  `DragTarget`) are fine — if you need a raw `GestureDetector` for one, put
  `// interactivity-ok` on that line so the guard allows it.

**Guard:** `tool/check_interactivity.sh` fails if a raw `GestureDetector`/
`InkWell` sneaks into `lib/screens/v2` or `lib/screens/auth`. Run it in CI or a
git pre-commit hook.

Note: `lib/screens/{today,chat,settings,onboarding}` and `app_shell.dart` are
dead v1 code (nothing routes to them) — the live app is `lib/screens/v2/*` +
`lib/screens/auth` + `splash_v2`/`root_gate`.
