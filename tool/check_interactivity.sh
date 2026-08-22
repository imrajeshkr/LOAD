#!/usr/bin/env bash
# Guard: every tappable in lib/screens must go through Pressable
# (lib/widgets/pressable.dart) so it gets the press-scale + haptic the whole
# app relies on. Raw GestureDetector / InkWell are not allowed there.
#
# Escape hatch: if a spot genuinely needs a raw gesture (pan, scale, custom
# drag), put `// interactivity-ok` on the same line to acknowledge it.
#
# Run manually, in CI, or from a git pre-commit hook.
set -euo pipefail
cd "$(dirname "$0")/.."

# Active app only. The legacy lib/screens/{today,chat,settings,onboarding} and
# app_shell.dart are dead v1 code (nothing routes to them) and are exempt.
DIRS="lib/screens/v2 lib/screens/auth"

violations=$(grep -rnE "GestureDetector\(|InkWell\(" $DIRS 2>/dev/null | grep -v "interactivity-ok" || true)

if [ -n "$violations" ]; then
  echo "❌ Raw GestureDetector/InkWell in lib/screens — wrap the tap in Pressable instead"
  echo "   (lib/widgets/pressable.dart). Add '// interactivity-ok' to bypass a real gesture case."
  echo
  echo "$violations"
  exit 1
fi

echo "✓ Every screen tap goes through Pressable."
