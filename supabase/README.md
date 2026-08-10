# LOAD — backend

## Layout

```
migrations/
  0001_init.sql              v1 (superseded)
  0002_units_and_metric.sql  v1 (superseded)
  0003_v2_schema.sql         ⚠ DESTRUCTIVE — drops v1, creates the v2 domain
  0004_coach_and_rpc.sql     coach memory, name resolution, program bootstrap
  0005_catalog_seed.sql      the global exercise catalog (36 movements)
  0006_coach_context_rpc.sql context-pack + progression RPCs
functions/coach/             the Gemini-backed coach Edge Function
seed_dummy_data.sql          ~9 weeks of history for one test account
design/                      the v2 schema design notes
```

## Applying the schema

`0003` **drops the v1 tables**. It is written for the current state of the
project — one real user plus dummy data — where a clean cutover is cheaper than
a staged migration. Take a backup first if that assumption no longer holds.

Verified locally against Postgres 17 before shipping:

```bash
docker run -d --name load-pg -e POSTGRES_PASSWORD=pg -p 55432:5432 postgres:17-alpine
```

Then apply `0003` → `0004` → `0005` → `0006` in order. Against the real project,
either paste them into the Supabase SQL editor in that order, or link the CLI
and push:

```bash
supabase link --project-ref <ref>
supabase db push
```

Afterwards, optionally seed a test account — edit the email at the top first:

```bash
psql "$DATABASE_URL" -f supabase/seed_dummy_data.sql
```

## Deploying the coach

The function needs its own secret; the app's `.env` is not visible to it.

```bash
supabase secrets set GEMINI_API_KEY=<key>
supabase functions deploy coach
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected by the platform. Optionally
pin a different model with `supabase secrets set GEMINI_MODEL=<id>`.

### Routes

| Route | Does |
|---|---|
| `POST /coach` | One chat turn. Returns `{ thread_id, reply, proposal }`. |
| `POST /coach/confirm` | Executes a proposal. **No model on this path.** |
| `POST /coach/reject` | Discards a proposal. |

All three require the caller's `Authorization: Bearer <user JWT>`.

### Two properties worth not breaking

**The function never uses `service_role`.** It builds its Supabase client from
the caller's JWT, so every read the context assembler makes is already
constrained by RLS. A prompt-injected model can ask for anything and still only
ever sees one lifter's data. Switching to `service_role` would turn every
injection bug into a cross-tenant leak.

**The model cannot write training data.** `propose_set_log` only inserts a
`pending` row in `coach_proposals`. Turning that into sets happens in
`/coach/confirm`, which is ordinary code, guarded by `status = 'pending'` so a
double tap or a retried request cannot double-log.

## Swapping the LLM provider

`functions/coach/gemini.ts` is the only file that knows the vendor. Everything
else — the context pack, the tool schemas, the proposal/confirm flow — is
provider-neutral. To move to another provider, reimplement `generate()` against
the same `GenerateResult` shape.

Gemini-specific details that live in that file, and would need an equivalent
elsewhere:

- `contents` roles are only `user` and `model`; there is no system role, so the
  system prompt goes in the separate top-level `systemInstruction`.
- Tool results go back as a **user** turn containing `functionResponse` parts.
- The model turn can carry `thoughtSignature` parts that must be echoed back
  verbatim, so the whole `parts` array is replayed rather than filtered.
- A blocked prompt returns HTTP 200 with **no candidates at all** — reading
  `candidates[0]` unconditionally is the standard way to crash here.
