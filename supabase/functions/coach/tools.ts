// =============================================================================
// The coach's tool surface.
//
// Read tools let it drill past the context pack. Proposal tools are the only
// way it can affect state, and every one of them terminates in a card the
// lifter has to accept — the model never writes training data.
//
// Note what the proposal tool takes: exercise NAMES, never ids. The model has
// no business inventing a UUID, and resolution is a deterministic server
// concern with a disambiguation path when it is not confident.
// =============================================================================

import type { FunctionDeclaration } from "./gemini.ts";
import { fmtWeight, toKg, type UserFacts } from "./context.ts";

// deno-lint-ignore no-explicit-any
type DB = any;

/** Below this, we ask instead of guessing which movement they meant. */
const CONFIDENT = 0.85;

export const DECLARATIONS: FunctionDeclaration[] = [
  {
    name: "get_exercise_history",
    description:
      "Recent logged sessions for one exercise, newest first, with top weight and best estimated 1RM. " +
      "Use when the lifter asks about progress, a stall, or what they lifted before.",
    parameters: {
      type: "object",
      properties: {
        exercise_name: { type: "string", description: "Exercise name as the lifter said it, e.g. 'bench'." },
        weeks: { type: "integer", description: "How far back to look. Defaults to 8." },
      },
      required: ["exercise_name"],
    },
  },
  {
    name: "get_next_load",
    description:
      "The suggested next working load for one exercise, with the reasoning behind it. " +
      "ALWAYS use this instead of calculating a progression yourself.",
    parameters: {
      type: "object",
      properties: {
        exercise_name: { type: "string", description: "Exercise name as the lifter said it." },
      },
      required: ["exercise_name"],
    },
  },
  {
    name: "propose_set_log",
    description:
      "Propose recording sets the lifter says they performed. This does NOT write anything — it " +
      "produces a confirmation card they must accept. Use whenever they report having done work. " +
      "Weights are in the lifter's display unit.",
    parameters: {
      type: "object",
      properties: {
        sets: {
          type: "array",
          description: "One entry per distinct weight/rep combination.",
          items: {
            type: "object",
            properties: {
              exercise_name: { type: "string", description: "As the lifter said it, e.g. 'bench'." },
              weight: { type: "number", description: "In the lifter's display unit." },
              reps: { type: "integer" },
              count: { type: "integer", description: "How many sets like this. Defaults to 1." },
            },
            required: ["exercise_name", "weight", "reps"],
          },
        },
      },
      required: ["sets"],
    },
  },
  {
    name: "remember",
    description:
      "Store a durable fact about this lifter that the database cannot derive — a preference, a " +
      "constraint, or the words they use for things. Do NOT store current numbers like a 1RM or " +
      "bodyweight; those are queries, not memories.",
    parameters: {
      type: "object",
      properties: {
        fact: { type: "string", description: "One short sentence, written in the third person." },
        kind: { type: "string", enum: ["preference", "constraint", "context", "vocabulary"] },
      },
      required: ["fact"],
    },
  },
];

export interface ToolOutcome {
  /** Returned to the model as the function result. */
  result: Record<string, unknown>;
  /** Set when the tool produced a card for the user to confirm. */
  proposalId?: string;
}

export async function runTool(
  db: DB,
  userId: string,
  facts: UserFacts,
  name: string,
  args: Record<string, unknown>,
  messageId: string,
): Promise<ToolOutcome> {
  switch (name) {
    case "get_exercise_history":   return await getExerciseHistory(db, userId, facts, args);
    case "get_next_load":          return await getNextLoad(db, userId, facts, args);
    case "propose_set_log":        return await proposeSetLog(db, userId, facts, args, messageId);
    case "remember":               return await remember(db, userId, args, messageId);
    default:
      return { result: { error: `Unknown tool "${name}".` } };
  }
}

// ── resolution ───────────────────────────────────────────────────────────
interface Resolved { id: string; name: string; score: number; }

async function resolve(db: DB, userId: string, term: string): Promise<Resolved[]> {
  const { data } = await db.rpc("resolve_exercise", { p_user_id: userId, p_name: term });
  // deno-lint-ignore no-explicit-any
  return (data ?? []).map((r: any) => ({ id: r.exercise_id, name: r.name, score: Number(r.score) }));
}

// ── read tools ───────────────────────────────────────────────────────────
async function getExerciseHistory(db: DB, userId: string, facts: UserFacts, args: Record<string, unknown>) {
  const term = String(args.exercise_name ?? "");
  const candidates = await resolve(db, userId, term);
  if (!candidates.length) return { result: { error: `No exercise matching "${term}".` } };

  const top = candidates[0];
  const { data } = await db.rpc("coach_exercise_history", {
    p_user_id: userId, p_exercise_id: top.id, p_weeks: Number(args.weeks ?? 8),
  });

  const unit = facts.units === "metric" ? "kg" : "lb";
  return {
    result: {
      exercise: top.name,
      unit,
      // Converted here so the model never sees a number in the wrong unit.
      sessions: (data ?? []).map((r: {
        performed_on: string; sets_summary: string; top_weight_kg: number; best_e1rm_kg: number;
      }) => ({
        date: r.performed_on,
        sets: convertSummary(r.sets_summary, facts.units),
        top_weight: fmtWeight(r.top_weight_kg, facts.units),
        best_e1rm: fmtWeight(r.best_e1rm_kg, facts.units),
      })),
    },
  };
}

async function getNextLoad(db: DB, userId: string, facts: UserFacts, args: Record<string, unknown>) {
  const term = String(args.exercise_name ?? "");
  const candidates = await resolve(db, userId, term);
  if (!candidates.length) return { result: { error: `No exercise matching "${term}".` } };

  const top = candidates[0];
  const { data } = await db.rpc("coach_next_load", { p_user_id: userId, p_exercise_id: top.id });
  const row = data?.[0];
  if (!row) return { result: { error: "No suggestion available." } };

  return {
    result: {
      exercise: top.name,
      suggested_weight: row.suggested_kg === null ? null : fmtWeight(row.suggested_kg, facts.units),
      unit: facts.units === "metric" ? "kg" : "lb",
      rationale: row.rationale,
    },
  };
}

// ── proposal tool ────────────────────────────────────────────────────────
interface ProposedSet {
  exercise_name?: unknown; weight?: unknown; reps?: unknown; count?: unknown;
}

async function proposeSetLog(
  db: DB, userId: string, facts: UserFacts,
  args: Record<string, unknown>, messageId: string,
): Promise<ToolOutcome> {
  const raw = Array.isArray(args.sets) ? (args.sets as ProposedSet[]) : [];
  if (!raw.length) return { result: { error: "No sets supplied." } };

  const rows: Record<string, unknown>[] = [];
  const ambiguous: Record<string, unknown>[] = [];

  for (const s of raw) {
    const term = String(s.exercise_name ?? "").trim();
    const weight = Number(s.weight);
    const reps = Math.trunc(Number(s.reps));
    const count = Math.max(1, Math.trunc(Number(s.count ?? 1)));

    // Validate server-side. The model's schema is a hint, not a guarantee.
    if (!term || !Number.isFinite(weight) || weight < 0 || !Number.isFinite(reps) || reps <= 0) {
      ambiguous.push({ term, reason: "incomplete or invalid" });
      continue;
    }

    const candidates = await resolve(db, userId, term);
    if (!candidates.length) {
      ambiguous.push({ term, reason: "no match in the catalog" });
      continue;
    }
    if (candidates[0].score < CONFIDENT) {
      ambiguous.push({ term, reason: "ambiguous", candidates: candidates.slice(0, 3).map((c) => c.name) });
      continue;
    }

    rows.push({
      exercise_id: candidates[0].id,
      exercise_name: candidates[0].name,
      weight_kg: round2(toKg(weight, facts.units)),
      reps,
      count,
    });
  }

  if (!rows.length) {
    return { result: { logged: false, needs_disambiguation: ambiguous,
      note: "Nothing could be resolved. Ask which exercise they meant." } };
  }

  const { data: proposal, error } = await db
    .from("coach_proposals")
    .insert({
      user_id: userId,
      message_id: messageId,
      kind: "log_sets",
      payload: { sets: rows, unit: facts.units },
      status: "pending",
    })
    .select("id")
    .single();

  if (error) return { result: { error: `Could not create the proposal: ${error.message}` } };

  return {
    proposalId: proposal.id,
    result: {
      logged: false,
      awaiting_confirmation: true,
      proposed: rows.map((r) => ({
        exercise: r.exercise_name,
        weight: fmtWeight(r.weight_kg as number, facts.units),
        unit: facts.units === "metric" ? "kg" : "lb",
        reps: r.reps, sets: r.count,
      })),
      needs_disambiguation: ambiguous.length ? ambiguous : undefined,
      note: "A confirmation card is now showing. Tell them to check it and confirm — do not claim it is logged.",
    },
  };
}

async function remember(db: DB, userId: string, args: Record<string, unknown>, messageId: string) {
  const fact = String(args.fact ?? "").trim();
  if (!fact) return { result: { error: "Empty fact." } };

  const kind = ["preference", "constraint", "context", "vocabulary"].includes(String(args.kind))
    ? String(args.kind) : "preference";

  // Cap it. Memory that grows without bound quietly becomes the whole prompt.
  const { count } = await db.from("coach_memories")
    .select("id", { count: "exact", head: true }).eq("user_id", userId);
  if ((count ?? 0) >= 50) {
    return { result: { stored: false, note: "Memory is full; ask them to prune it in Settings." } };
  }

  const { error } = await db.from("coach_memories")
    .insert({ user_id: userId, fact, kind, source_message_id: messageId });

  return error
    ? { result: { stored: false, error: error.message } }
    : { result: { stored: true } };
}

// "80.00x8, 82.50x6" is stored in kg; restate it in the lifter's unit.
function convertSummary(summary: string | null, units: "metric" | "imperial"): string {
  if (!summary) return "";
  if (units === "metric") return summary.replace(/(\d+)\.00/g, "$1");
  return summary.replace(/([\d.]+)x(\d+)/g, (_m, w, r) => `${fmtWeight(Number(w), units)}x${r}`);
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
