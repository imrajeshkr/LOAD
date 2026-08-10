// =============================================================================
// LOAD — coach Edge Function
//
// Three routes:
//   POST /coach            a chat turn. May return a pending proposal.
//   POST /coach/confirm    execute a proposal. NO MODEL ON THIS PATH.
//   POST /coach/reject     discard a proposal.
//
// The security design is in which credential this uses: it builds a Supabase
// client from the CALLER'S JWT, never from service_role. Every read the
// context assembler makes is therefore already constrained by RLS, so a
// prompt-injected model can ask for anything and still only ever see one
// lifter's data. With service_role, every injection bug would be a
// cross-tenant leak.
// =============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { generate, GeminiError, MODEL, type Content } from "./gemini.ts";
import { buildStablePrefix, buildLiveContext } from "./context.ts";
import { DECLARATIONS, runTool } from "./tools.ts";

// The generated client generics differ between construction sites; the data
// layer here is hand-checked against the SQL, so keep it loose and uniform
// with context.ts and tools.ts.
// deno-lint-ignore no-explicit-any
type DB = any;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** The agent loop is shallow by design — read tools then answer. */
const MAX_TOOL_ROUNDS = 3;
/** Verbatim turns kept in the prompt. Older turns are dropped, not replayed. */
const HISTORY_TURNS = 12;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const auth = req.headers.get("Authorization");
    if (!auth) return json({ error: "Missing Authorization header" }, 401);

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: auth } } },
    );

    const { data: userData, error: userErr } = await db.auth.getUser();
    if (userErr || !userData?.user) return json({ error: "Not signed in" }, 401);
    const userId = userData.user.id;

    const action = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop();
    const body = await req.json().catch(() => ({}));

    switch (action) {
      case "confirm": return await confirmProposal(db, userId, body);
      case "reject":  return await rejectProposal(db, userId, body);
      default:        return await chatTurn(db, userId, body);
    }
  } catch (err) {
    console.error("coach: unhandled", err);
    const detail = err instanceof GeminiError ? err.body : String(err);
    return json({ error: "The coach is unavailable right now.", detail }, 500);
  }
});

// ── a chat turn ──────────────────────────────────────────────────────────
async function chatTurn(db: DB, userId: string, body: Record<string, unknown>) {
  const text = String(body.text ?? "").trim();
  if (!text) return json({ error: "Empty message" }, 400);

  const threadId = await ensureThread(db, userId, String(body.thread_id ?? "") || null);

  // Persist the user's turn first so nothing is lost if generation fails.
  const { data: userMsg } = await db.from("coach_messages")
    .insert({ user_id: userId, thread_id: threadId, role: "user", content: text })
    .select("id").single();

  // Context is assembled stable-part-first so the prefix stays byte-identical
  // between turns and the provider's implicit cache can hit.
  const { prefix, facts } = await buildStablePrefix(db, userId);
  const live = await buildLiveContext(db, userId, facts);

  const history = await loadHistory(db, threadId);

  // Gemini has no system role inside `contents`, so live state rides at the
  // front of the current user turn rather than being edited into the system
  // instruction — editing that would invalidate the whole cached prefix.
  const contents: Content[] = [
    ...history,
    { role: "user", parts: [{ text: `${live}\n\n---\n\n${text}` }] },
  ];

  let proposalId: string | undefined;
  let reply = "";
  let rounds = 0;

  while (rounds < MAX_TOOL_ROUNDS) {
    rounds++;
    const res = await generate({
      systemInstruction: prefix,
      contents,
      tools: DECLARATIONS,
      thinkingLevel: "low",
    });

    if (res.blocked) {
      reply = "I can't help with that one. Ask me about your training and I'll pick it back up.";
      console.warn("coach: blocked", res.blockReason, res.finishReason);
      break;
    }

    if (!res.functionCalls.length) {
      reply = res.text.trim();
      break;
    }

    // Replay the model turn verbatim — it can carry thoughtSignature parts
    // that must be echoed back unaltered on Gemini 3.x.
    if (res.content) contents.push(res.content);

    const responseParts = [];
    for (const call of res.functionCalls) {
      const outcome = await runTool(db, userId, facts, call.name, call.args ?? {}, userMsg?.id ?? "");
      if (outcome.proposalId) proposalId = outcome.proposalId;
      responseParts.push({
        functionResponse: { id: call.id, name: call.name, response: outcome.result },
      });
    }
    contents.push({ role: "user", parts: responseParts });

    // Any text alongside the call is preamble; keep it only as a fallback.
    if (res.text.trim()) reply = res.text.trim();
  }

  if (!reply) reply = "I got a bit lost there — say that again?";

  const { data: assistantMsg } = await db.from("coach_messages")
    .insert({ user_id: userId, thread_id: threadId, role: "assistant", content: reply, model: MODEL })
    .select("id").single();

  // Attach the proposal to the reply the user actually sees.
  if (proposalId && assistantMsg?.id) {
    await db.from("coach_proposals").update({ message_id: assistantMsg.id }).eq("id", proposalId);
  }

  await db.from("coach_threads").update({ last_message_at: new Date().toISOString() }).eq("id", threadId);

  return json({
    thread_id: threadId,
    reply,
    proposal: proposalId ? await readProposal(db, userId, proposalId) : null,
  });
}

// ── confirm: deterministic, no model ─────────────────────────────────────
async function confirmProposal(db: DB, userId: string, body: Record<string, unknown>) {
  const proposalId = String(body.proposal_id ?? "");
  if (!proposalId) return json({ error: "Missing proposal_id" }, 400);

  // The status guard is the idempotency key: a double tap or a retried
  // request finds the row already confirmed and changes nothing.
  const { data: claimed, error: claimErr } = await db
    .from("coach_proposals")
    .update({ status: "confirmed", resolved_at: new Date().toISOString() })
    .eq("id", proposalId).eq("user_id", userId).eq("status", "pending")
    .select("id, kind, payload").maybeSingle();

  if (claimErr) return json({ error: claimErr.message }, 400);
  if (!claimed) return json({ ok: true, already_resolved: true });

  if (claimed.kind !== "log_sets") {
    return json({ error: `Unsupported proposal kind "${claimed.kind}"` }, 400);
  }

  // deno-lint-ignore no-explicit-any
  const sets = ((claimed.payload as any)?.sets ?? []) as Array<{
    exercise_id: string; exercise_name: string; weight_kg: number; reps: number; count: number;
  }>;

  // Reuse an open session if there is one, so chat-logged sets land in the
  // session the lifter is actually doing rather than a stray second row.
  const { data: open } = await db.from("workout_sessions")
    .select("id").eq("user_id", userId).eq("status", "in_progress").maybeSingle();

  let sessionId = open?.id as string | undefined;
  if (!sessionId) {
    const { data: created, error } = await db.from("workout_sessions")
      .insert({ user_id: userId, title: "Logged from chat", status: "completed",
                completed_at: new Date().toISOString() })
      .select("id").single();
    if (error) return await failProposal(db, proposalId, error.message);
    sessionId = created.id;
  }

  for (const s of sets) {
    // The unique constraint on session_exercises is (session_id, ordinal),
    // not (session_id, exercise_id) — so an upsert would happily create a
    // second row for the same movement. Look it up, then insert if missing.
    const { data: found } = await db.from("session_exercises")
      .select("id").eq("session_id", sessionId!).eq("exercise_id", s.exercise_id).maybeSingle();

    let sessionExerciseId = found?.id as string | undefined;
    if (!sessionExerciseId) {
      const { data: created, error: seErr } = await db.from("session_exercises")
        .insert({ user_id: userId, session_id: sessionId, exercise_id: s.exercise_id,
                  ordinal: await nextOrdinal(db, sessionId!) })
        .select("id").single();
      if (seErr) return await failProposal(db, proposalId, seErr.message);
      sessionExerciseId = created.id;
    }

    const se = { id: sessionExerciseId! };
    const base = await nextSetNumber(db, se.id);
    const rows = Array.from({ length: s.count }, (_, i) => ({
      user_id: userId, session_exercise_id: se.id,
      set_number: base + i, weight_kg: s.weight_kg, reps: s.reps,
    }));
    const { error: setErr } = await db.from("session_sets").insert(rows);
    if (setErr) return await failProposal(db, proposalId, setErr.message);
  }

  await db.from("coach_proposals").update({ result_session_id: sessionId }).eq("id", proposalId);

  return json({ ok: true, session_id: sessionId,
    sets_logged: sets.reduce((n, s) => n + s.count, 0) });
}

async function rejectProposal(db: DB, userId: string, body: Record<string, unknown>) {
  const proposalId = String(body.proposal_id ?? "");
  if (!proposalId) return json({ error: "Missing proposal_id" }, 400);
  await db.from("coach_proposals")
    .update({ status: "rejected", resolved_at: new Date().toISOString() })
    .eq("id", proposalId).eq("user_id", userId).eq("status", "pending");
  return json({ ok: true });
}

// ── helpers ──────────────────────────────────────────────────────────────
async function failProposal(db: DB, proposalId: string, message: string) {
  // Put it back so the lifter can retry rather than losing the card.
  await db.from("coach_proposals")
    .update({ status: "pending", resolved_at: null }).eq("id", proposalId);
  return json({ error: `Could not log that: ${message}` }, 500);
}

async function ensureThread(db: DB, userId: string, threadId: string | null) {
  if (threadId) return threadId;
  const { data: existing } = await db.from("coach_threads")
    .select("id").eq("user_id", userId)
    .order("last_message_at", { ascending: false }).limit(1).maybeSingle();
  if (existing) return existing.id as string;

  const { data: created, error } = await db.from("coach_threads")
    .insert({ user_id: userId, title: "Coach" }).select("id").single();
  if (error) throw error;
  return created.id as string;
}

async function loadHistory(db: DB, threadId: string): Promise<Content[]> {
  const { data } = await db.from("coach_messages")
    .select("role, content").eq("thread_id", threadId)
    .in("role", ["user", "assistant"])
    .order("created_at", { ascending: false }).limit(HISTORY_TURNS);

  // Fetched newest-first so the limit keeps the RECENT turns, then reversed.
  // Ordering ascending with a limit would keep the oldest, which is the
  // opposite of what a conversation needs.
  return (data ?? []).reverse().map((m: { role: string; content: string }) => ({
    role: m.role === "assistant" ? "model" as const : "user" as const,
    parts: [{ text: m.content }],
  }));
}

async function readProposal(db: DB, userId: string, id: string) {
  const { data } = await db.from("coach_proposals")
    .select("id, kind, payload, status").eq("id", id).eq("user_id", userId).maybeSingle();
  return data;
}

async function nextOrdinal(db: DB, sessionId: string) {
  const { data } = await db.from("session_exercises")
    .select("ordinal").eq("session_id", sessionId)
    .order("ordinal", { ascending: false }).limit(1).maybeSingle();
  return (data?.ordinal ?? 0) + 1;
}

async function nextSetNumber(db: DB, sessionExerciseId: string) {
  const { data } = await db.from("session_sets")
    .select("set_number").eq("session_exercise_id", sessionExerciseId)
    .order("set_number", { ascending: false }).limit(1).maybeSingle();
  return (data?.set_number ?? 0) + 1;
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status, headers: { ...CORS, "content-type": "application/json" },
  });
}
