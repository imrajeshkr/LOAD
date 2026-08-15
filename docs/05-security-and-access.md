# LOAD — Security & Access Document

**Status:** Draft v1 — third of five planning documents. Builds on the
Technical Architecture document. This is not a restatement of known
invariants from memory — every claim below was re-verified against the
actual migrations, RLS policies, and Edge Function source while writing
this document, and it surfaced one real, previously-undocumented
authorization gap (§5.1). Findings are reported plainly, including the ones
that make the current build look less finished than the working demo
suggests — that's the point of doing this pass now, before public
distribution is on the table.

---

## 1. Trust boundaries

Today: one real user, one Supabase project, one Google Cloud (Gemini) API
key. The threat model that matters *now* is narrow. The threat model this
document is actually written for is the one the PRD flags as the reason
auth exists at all: **v2, when a second real user's data lives in the same
tables as the first.** Every finding below is graded against that future
state, not against "can the founder attack their own account" — because a
gap that's harmless at n=1 becomes a real cross-tenant leak the moment
that's no longer true, and the schema is multi-tenant-shaped *today* even
though the product isn't yet.

## 2. Authentication

- Google Sign-In + email/password (with confirm-password on signup), via
  Supabase Auth. Session tokens (JWTs) issued and refreshed by Supabase's
  own client SDK — the app never implements its own token logic.
  Password reset in Supabase Auth already ships forgot-password; it's
  simply not wired into the app's UI yet (PRD §8 — deliberate cut for the
  current single-known-user state, not a missing capability if this
  changes).
- No hard requirement that email be verified before use — not currently
  enforced client- or server-side. Fine for a single known account; a real
  gap to close before any public sign-up surface opens (§6, ticket-worthy).

## 3. Authorization model

**Row-Level Security is the actual authorization boundary — not an
app-layer check that happens to also be true.** Every user-owned table
(`profiles`, `training_profiles`, `workout_sessions`, `session_sets`,
`coach_messages`, `coach_proposals`, and 13 others) is covered by one
generated policy loop in `0003_v2_schema.sql`:

```sql
create policy <table>_own on <table> for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
```

(`profiles` uses `id` instead of `user_id`; three program-child tables with
no `user_id` of their own use an `exists (...)` predicate up to the owning
`programs` row instead — same effect, necessary shape.)

Catalog tables (`exercises`, `muscles`, `joints`, etc.) are readable by any
authenticated user, writable only by the service role — no write policy
exists for them under RLS, which is the correct way to express
"nobody but an operator changes the exercise catalog."

**Default posture for every RPC: `security invoker`.** A function declared
this way runs as the calling user's own role, so every query inside it is
still subject to RLS regardless of what parameters are passed in — this is
why `today_plan(p_user_id uuid)` is safe to call with any uuid: pass a
different user's id and the query returns nothing, because RLS still
filters by the caller's *real* `auth.uid()`, not the parameter. This
property is why the RPC surface can freely take `p_user_id` as an explicit
parameter (useful for `security invoker` internal composition) without
that parameter being an attack surface — **for every function except the
one below.**

## 4. AI write-safety — verified against the running code, both invariants hold

Two invariants, previously stated in `HANDOFF.md`, re-verified line-by-line
against `supabase/functions/coach/index.ts` while writing this document,
not assumed:

**1. The coach Edge Function never uses `service_role`.**
```ts
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_ANON_KEY")!,
  { global: { headers: { Authorization: auth } } },
);
```
It builds its Supabase client from the *caller's own JWT*, forwarded from
the request's `Authorization` header — the anon key plus that header is
what actually resolves identity, exactly as the Flutter client itself
would. Every read the context assembler makes is RLS-constrained the same
way a direct client query would be. A prompt-injected model reasoning
inside this function still can't see or touch another user's row, because
the database connection itself doesn't have the privilege to, regardless
of what the model asks for.

Confirmed further: `userId` is taken from `db.auth.getUser()` — a
server-side validation of the JWT — never from a client-supplied field in
the request body. A malicious client sending a spoofed `user_id` in the
POST body has no effect; it's never read.

**2. The model never writes training data directly.**
The only state-changing tool available to the model is `propose_set_log`,
which inserts a `pending` row into `coach_proposals`. Confirming
(`/coach/confirm`) is a separate, deterministic, model-free code path:
read the pending proposal → write the sets → mark `confirmed`, guarded by
`.eq("status", "pending")` so a retried or double-tapped confirm changes
zero rows (verified against production). No tool exists that reaches
`session_sets` in the same call that invokes the model.

Both invariants are structural, not policy — breaking either would require
an actual code change to this one function, not a prompt or config
mistake. That's the right shape for a control this load-bearing.

**Reviewed and not a real issue:** `coach_proposals`' RLS policy is `for
all` (full CRUD) to the owning user, meaning a client could in principle
insert a hand-crafted `coach_proposals` row directly via REST, bypassing
the model, then confirm it. This sounds concerning on first read but isn't
a real gap: `/coach/confirm` scopes every operation to
`.eq("user_id", userId)` from the caller's own validated JWT, so a
self-crafted proposal can only ever write *that same user's own* training
data — which they already have full, unmediated rights to do through the
ordinary logging RPCs anyway. No privilege crosses a boundary. Documented
here so this exact question doesn't get re-asked and re-investigated from
scratch later.

## 5. Findings

### 5.1 `bootstrap_user_program(uuid)` does not validate its own parameter — real gap

`bootstrap_user_program(p_user_id uuid)` (`0004_coach_and_rpc.sql`,
re-declared in `0008`/`0009`) is `security definer` — it runs with the
*function owner's* privileges, not the caller's, which is what lets it
write across `programs`/`program_days`/`program_day_exercises`/
`scheduled_workouts` in one call. That's a legitimate reason to use
`security definer`. But it is also directly granted to `authenticated`:

```sql
revoke all on function bootstrap_user_program(uuid) from public;
grant execute on function bootstrap_user_program(uuid) to authenticated;
```

and the function body never checks that `p_user_id = auth.uid()`. Today
this only matters for the one real account, where every possible
`p_user_id` value resolves to the same person. The moment a second real
user exists, **any authenticated user could call this RPC directly (not
through the app — a raw `POST /rest/v1/rpc/bootstrap_user_program` with a
different `p_user_id` in the body) and archive and regenerate a stranger's
active training program**, because `security definer` means RLS does not
apply inside this function at all — the self-check is the *only* line of
defense, and it doesn't exist.

The safe wrapper `bootstrap_my_program()` (no arguments, `security
invoker`, internally calls `bootstrap_user_program(auth.uid())`) is what
the client actually calls — but PostgREST exposes every granted function
by name regardless of which one the app happens to use, so the unsafe
one being directly callable is a real, live gap, not a theoretical one.

**Recommended fix** (small, self-contained, doesn't touch the wrapper or
any caller): add a self-check as the first statement in
`bootstrap_user_program`'s body:
```sql
if p_user_id <> auth.uid() then
  raise exception 'not authorized';
end if;
```
This makes the function safe to keep granted directly (defense in depth)
without restructuring the two-function split, and matches the pattern
`security definer` functions taking a target-user argument should always
follow. Not applied yet — flagged here for a decision, tracked as a ticket
(§7).

### 5.2 No email verification gate

Noted in §2. Low urgency at n=1; blocking for any public sign-up surface.

### 5.3 No data export or account deletion flow

Nothing in the app or backend currently lets a user export or delete their
own data end-to-end (RLS means they could delete their own rows table by
table via direct queries, but there's no supported flow, and auth-account
deletion isn't wired to a corresponding data cleanup). Not urgent for a
single known user who is also the operator. A hard requirement — not a
nice-to-have — before any public distribution under GDPR/CCPA-adjacent
expectations, even informally. Tracked as a ticket (§7), explicitly not
scheduled against a date.

## 6. Data classification

| Class | Examples | Handling |
|---|---|---|
| Public/catalog | Exercise names, cues, demo media | Read-only to any authenticated user; media bucket is public-read by design (not personal data) |
| Personal — training | Logged sets, sessions, program | RLS-scoped to owner; never leaves Supabase except into the Gemini prompt for that same user's own coach turn |
| Personal — sensitive | Injuries/constraints, pain reports, bodyweight | Same RLS scoping; no different technical handling today, but worth flagging as the category most likely to warrant explicit consent language if this ever becomes multi-tenant (injury/health-adjacent data reads differently under most privacy frameworks than a bench-press number does) |
| Credentials | Auth tokens, Gemini API key | Tokens managed entirely by Supabase Auth SDK; `GEMINI_API_KEY` is an Edge Function secret, never in client code, never in a committed file (verified: `.env`/`.env.*` gitignored, only `.env.example` tracked) |
| Never present | `service_role` key in client code | Verified by search: the string appears only in a doc comment warning against it (`lib/services/supabase_service.dart`) and in the Edge Function's own comment explaining why it doesn't use one — no actual credential value anywhere in the repo |

## 7. Recommendations, prioritized

1. **Fix §5.1** — add the `p_user_id = auth.uid()` self-check to
   `bootstrap_user_program`. Small, safe, no behavior change for the
   legitimate path. Do this before any second account ever exists in the
   same project, including a test account.
2. **Decide on §5.3** (data export/delete) as a real requirement gated on
   "before public distribution," not "someday" — it has legal weight that
   most other backlog items don't.
3. **§5.2** (email verification) — bundle with whatever work eventually
   builds a real sign-up surface (PRD §7.1); no reason to build it before
   there's a sign-up flow worth protecting.

These are also added to the Feature Ticket List as a new security section
so they don't live only in this document.

## 8. What's already correct (worth stating, not just gaps)

- RLS-by-default across every user table, generated from one pattern
  rather than hand-authored per table — the kind of consistency that
  prevents "we forgot a policy on the new table" bugs.
- The AI write-safety design (§4) is genuinely sound, verified at the code
  level, not just documented as an intention.
- No secrets in the client bundle or repo history at the paths checked.
- `security invoker` as the default RPC posture, with the one exception
  now identified and fix-ready rather than latent.

---

*This closes the five-document set: `01`/`03` (product), `04` (this doc's
predecessor), `05` (this document), `06` (frontend), `07` (tickets).*
