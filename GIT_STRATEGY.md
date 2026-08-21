# Git Strategy — LOAD

The team workflow for shipping fixes, features, and everything in between.
Keep `main` always releasable; keep history readable; never surprise a teammate.

---

## 1. Branching

- **`main`** is the single source of truth and must always build and run. Never
  commit directly to `main` for anything non-trivial — branch first.
- Cut every branch **from an up-to-date `main`**:
  ```bash
  git checkout main
  git pull --rebase origin main
  git checkout -b <type>/<short-description>
  ```

### Branch naming

`<type>/<short-kebab-description>` — e.g.:

| Type       | Use for                                  | Example                          |
|------------|------------------------------------------|----------------------------------|
| `feat/`    | new user-facing capability               | `feat/animated-splash`           |
| `fix/`     | bug fix                                   | `fix/google-signin-ios-nonce`    |
| `chore/`   | tooling, deps, config, no behavior change | `chore/bump-flutter-3.41`        |
| `refactor/`| code change with no behavior change       | `refactor/auth-service`          |
| `docs/`    | docs only                                 | `docs/git-strategy`              |

Keep branches **small and single-purpose**. One branch = one reviewable idea.

---

## 2. Commits

We use **[Conventional Commits](https://www.conventionalcommits.org/)** (already
the convention in this repo's history):

```
<type>(optional scope): <imperative summary>

<optional body: what & why, not how>
```

Examples:
```
feat: add animated grow/play splash screen
fix: skip nonce check for iOS Google sign-in
chore: generate launcher icons from brand assets
```

Rules:
- **Imperative mood** ("add", not "added"/"adds").
- Summary ≤ 72 chars, no trailing period.
- Commit **logical units**, not "wip" dumps. Squash noise before pushing.
- Never commit secrets, `.env`, or personal machine config.
- **No AI attribution.** Never add "Authored by Claude", "Generated with
  Claude Code", `Co-Authored-By: Claude`, or any similar AI-tool credit to a
  commit message, PR title, PR body, or review comment. Commits and PRs are
  authored by the human developer, full stop.

---

## 3. What NOT to commit

Machine-generated / environment-specific noise that Flutter, Xcode, Gradle, or
CocoaPods regenerate on the next build. Committing it churns teammates' trees
and causes pointless conflicts. Before every commit, run `git status` and
**review each file** — if you didn't intentionally change it, don't stage it.

Typically **do not** commit (unless the change is intentional and shared):
- `pubspec.lock` transitive bumps you didn't ask for
- `android/gradle.properties`, `*.xcconfig` auto-"upgrades" from tooling
- `ios/**/xcshareddata/swiftpm/`, generated `Podfile`/`Podfile.lock` churn
- `.DS_Store`, IDE files, anything under `build/`

**Do** commit intentional native changes — e.g. generated launcher icons,
native splash assets, `Info.plist` edits for real features (URL schemes, etc.).

> Rule of thumb: dashboard/config fixes (Supabase, GCP, Firebase) live in those
> consoles, **not** in code. Don't manufacture a commit for a fix that wasn't
> a code change.

---

## 4. Staying in sync — rebase, don't merge

Keep a **linear history**. Always rebase your branch onto latest `main`:

```bash
git fetch origin
git rebase origin/main          # replay your work on top of latest main
# resolve conflicts, then:
git rebase --continue
```

- **Never** `git merge main` into a feature branch (avoids "Merge branch 'main'"
  noise commits).
- If you already pushed and rebased, update the remote with a **safe** force:
  ```bash
  git push --force-with-lease
  ```
  Never plain `git push --force` — `--force-with-lease` refuses to clobber a
  teammate's newer work.

---

## 5. Pull Requests

1. Push your branch: `git push -u origin <branch>`.
2. Open a PR into `main`. Title = the Conventional-Commit summary.
3. PR description: **what changed, why, how you tested** (device/simulator,
   screenshots for UI). Link any relevant dashboard changes (Supabase/GCP).
4. At least **one review** before merge. Keep PRs small enough to review well.
5. **Squash and merge** so `main` gets one clean commit per PR.
6. Delete the branch after merge.

---

## 6. Before you push — checklist

```bash
flutter analyze          # no new errors
flutter test             # if tests exist for the area
git status               # nothing unintended staged
git log --oneline -5     # history reads cleanly
```

- The app **builds and runs** on at least one platform you touched.
- No secrets, no machine-specific noise, no debug prints left behind.

---

## 7. Hotfixes

For an urgent production fix: branch `fix/...` from `main`, keep it minimal,
fast-track the review, squash-merge. Same rules, tighter loop.

---

## 8. Environment note (this repo)

GitHub SSH is routed over port 443 (`ssh.github.com`) in `~/.ssh/config`
because port 22 is blocked on some networks. Org access (`sk-kitab`) is on the
`id_ed25519_kitab` key. If `git fetch` times out, that config is the fix.

Per-developer Android debug keystores have unique SHA-1s: each dev must add
their own SHA-1 as a new Android OAuth client in GCP (see project onboarding).
iOS needs no per-device setup (keyed by bundle ID, not SHA-1).
