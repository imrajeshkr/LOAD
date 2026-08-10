// =============================================================================
// Context assembly.
//
// Sorted by rate of change so the stable part sits at the front of the prompt
// and stays byte-identical between turns — that is what lets the provider's
// prefix cache do its job.
//
//   buildStablePrefix()  T0–T2  persona, catalog, profile   — changes ~daily
//   buildLiveContext()   T3–T4  training state, live session — every turn
//
// Nothing here dumps raw rows. Every fact is pre-aggregated by SQL into a
// compact line, because the model reasons better over the summary and the
// pack is a stable artifact you can diff when behaviour changes.
// =============================================================================

// deno-lint-ignore no-explicit-any
type DB = any;

export interface UserFacts {
  units: "metric" | "imperial";
  timezone: string;
  displayName: string | null;
}

const COACH_PERSONA = `
You are the strength coach inside LOAD, a training app. You speak to one lifter
about their own training.

How you talk:
- Direct and specific. No preamble, no hype, no emoji.
- Two or three sentences unless they asked for depth.
- You are a coach, not a doctor. If something sounds like an injury rather than
  ordinary soreness, say so plainly and suggest they get it looked at.

Reading their messages:
- A message that is just an exercise and numbers is ALWAYS a report of work
  they performed, never a question. "bench 80x8x4", "hammer curls 14x12x3",
  "face pulls 15x20x3" all mean weight x reps x sets — call propose_set_log
  immediately. Do not answer these with advice; the app's own input hint
  teaches this shorthand, so it has to work every time.
- Only treat it as a question if they actually ask one.

Rules you do not break:
- Never state a number that is not in the context below or in a tool result.
  If you do not have it, call a tool or say you do not have it.
- Never do arithmetic on training data yourself. Volume, estimated 1RMs and
  next-load suggestions come from tools. You decide whether to progress and
  explain why; the tool supplies the number.
- Never claim you logged something. You can only propose a log, which the
  lifter confirms. Say "confirm below" and stop.
- If an exercise is marked CONTRAINDICATED, do not program it. Offer the listed
  substitute instead.
- Weights in your replies use the lifter's display unit, shown below.
`.trim();

/** T0–T2. Stable across turns; keep it byte-identical to earn the cache. */
export async function buildStablePrefix(db: DB, userId: string): Promise<{ prefix: string; facts: UserFacts }> {
  const [profileRes, prefsRes, tpRes, constraintsRes, memoriesRes] = await Promise.all([
    db.from("profiles").select("display_name, timezone").eq("id", userId).maybeSingle(),
    db.from("user_preferences").select("units, weight_increment_kg").eq("user_id", userId).maybeSingle(),
    db.from("training_profiles")
      .select("goal, experience, environment, split_preference, days_per_week, target_weight_kg")
      .eq("user_id", userId).is("valid_to", null).maybeSingle(),
    db.from("user_constraints").select("label, severity, joint_id, joints(name)").eq("user_id", userId).is("active_to", null),
    db.from("coach_memories").select("fact, kind").eq("user_id", userId).order("created_at", { ascending: false }).limit(25),
  ]);

  const units = (prefsRes.data?.units ?? "metric") as "metric" | "imperial";
  const unitLabel = units === "metric" ? "kg" : "lb";
  const tp = tpRes.data;

  const lines: string[] = [COACH_PERSONA, "", "## This lifter"];
  lines.push(`- Display unit: ${unitLabel} (all weights below and in your replies use this unit)`);
  if (tp) {
    lines.push(`- Goal: ${human(tp.goal)} · Experience: ${human(tp.experience)}`);
    lines.push(`- Trains: ${human(tp.split_preference)}, ${tp.days_per_week}x/week, ${human(tp.environment)}`);
    if (tp.target_weight_kg) lines.push(`- Target bodyweight: ${fmtWeight(tp.target_weight_kg, units)} ${unitLabel}`);
  } else {
    lines.push("- No training profile set yet. Ask before assuming a goal or split.");
  }

  const constraints = constraintsRes.data ?? [];
  if (constraints.length) {
    lines.push("", "## Flagged limitations");
    for (const c of constraints) {
      // deno-lint-ignore no-explicit-any
      const joint = (c as any).joints?.name ?? "unspecified";
      lines.push(`- ${c.label} (${joint}, ${c.severity})`);
    }
  }

  const memories = memoriesRes.data ?? [];
  if (memories.length) {
    lines.push("", "## Remembered about them");
    for (const m of memories) lines.push(`- ${m.fact}`);
  }

  // Catalog, filtered to what this lifter's gym can actually equip, with
  // anything that stresses a flagged joint marked. The injury filter is a
  // query, not an instruction the model is asked to follow.
  const { data: catalog } = await db.rpc("coach_catalog", { p_user_id: userId });
  if (catalog?.length) {
    lines.push("", "## Exercises available to them",
      "(name — pattern — primary muscles. CONTRAINDICATED means do not program it;",
      " CAUTION means it is fine to program but mention the joint.)");
    for (const e of catalog) {
      let flag = "";
      if (e.contraindicated) flag = "  ⚠ CONTRAINDICATED";
      else if (e.caution) flag = `  ⚠ CAUTION: ${e.caution}`;
      const alt = e.substitute && (e.contraindicated || e.caution) ? ` → swap: ${e.substitute}` : "";
      lines.push(`- ${e.name} — ${e.pattern ?? "other"} — ${e.muscles ?? "—"}${flag}${alt}`);
    }
  }

  return {
    prefix: lines.join("\n"),
    facts: {
      units,
      timezone: profileRes.data?.timezone ?? "UTC",
      displayName: profileRes.data?.display_name ?? null,
    },
  };
}

/** T3–T4. Rebuilt every turn; kept small on purpose. */
export async function buildLiveContext(db: DB, userId: string, facts: UserFacts): Promise<string> {
  const { units, timezone } = facts;
  const unitLabel = units === "metric" ? "kg" : "lb";

  const [todayRes, openRes, recentRes, volumeRes, bodyRes, nutritionRes] = await Promise.all([
    db.from("scheduled_workouts")
      .select("scheduled_for, status, program_days(label, program_day_exercises(ordinal, sets_target, rep_low, rep_high, target_weight_kg, exercises(name)))")
      .eq("user_id", userId).eq("status", "pending")
      .order("scheduled_for", { ascending: true }).limit(1).maybeSingle(),
    db.from("workout_sessions").select("id, title, started_at").eq("user_id", userId).eq("status", "in_progress").maybeSingle(),
    db.from("v_session_totals").select("title, performed_on, set_count, volume_kg").eq("user_id", userId)
      .order("performed_on", { ascending: false }).limit(5),
    db.rpc("coach_weekly_volume", { p_user_id: userId }),
    db.from("body_measurements").select("measured_on, weight_kg").eq("user_id", userId)
      .not("weight_kg", "is", null).order("measured_on", { ascending: false }).limit(2),
    db.from("v_nutrition_daily").select("logged_on, protein_g, protein_target_g").eq("user_id", userId)
      .order("logged_on", { ascending: false }).limit(1).maybeSingle(),
  ]);

  const now = new Date();
  const local = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone, weekday: "long", day: "numeric", month: "long",
    hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(now);

  const lines: string[] = ["## Right now", `- Local time for them: ${local} (${timezone})`];

  const open = openRes.data;
  if (open) {
    lines.push(`- They are MID-SESSION: "${open.title}", started ${timeAgo(open.started_at)} ago.`);
  }

  const today = todayRes.data;
  // deno-lint-ignore no-explicit-any
  const day: any = today?.program_days;
  if (day) {
    lines.push("", `## Next scheduled: ${day.label} (${today.scheduled_for})`);
    const planned = [...(day.program_day_exercises ?? [])].sort((a, b) => a.ordinal - b.ordinal);
    for (const p of planned) {
      const target = p.target_weight_kg ? ` @ ${fmtWeight(p.target_weight_kg, units)} ${unitLabel}` : "";
      lines.push(`- ${p.exercises?.name} — ${p.sets_target}×${p.rep_low}-${p.rep_high}${target}`);
    }
  } else {
    lines.push("- Nothing scheduled. They may need a program generated.");
  }

  const recent = recentRes.data ?? [];
  if (recent.length) {
    lines.push("", "## Last sessions");
    for (const s of recent) {
      lines.push(`- ${s.performed_on} · ${s.title} · ${s.set_count} sets · ${fmtWeight(s.volume_kg, units)} ${unitLabel} volume`);
    }
  }

  const volume = volumeRes.data ?? [];
  if (volume.length) {
    lines.push("", "## Hard sets per muscle, last 4 weeks");
    lines.push(volume.map((v: { muscle: string; sets: number }) => `${v.muscle} ${Number(v.sets).toFixed(0)}`).join(" · "));
  }

  const body = bodyRes.data ?? [];
  if (body.length) {
    const latest = body[0];
    let trend = "";
    if (body.length > 1) {
      const delta = Number(latest.weight_kg) - Number(body[1].weight_kg);
      trend = ` (${delta >= 0 ? "+" : ""}${fmtWeight(Math.abs(delta) * (delta < 0 ? -1 : 1), units)} since ${body[1].measured_on})`;
    }
    lines.push("", `## Bodyweight`, `- ${fmtWeight(latest.weight_kg, units)} ${unitLabel} on ${latest.measured_on}${trend}`);
  }

  const nutrition = nutritionRes.data;
  if (nutrition) {
    lines.push("", `## Nutrition`, `- ${Math.round(nutrition.protein_g)}g protein on ${nutrition.logged_on}` +
      (nutrition.protein_target_g ? ` (target ${nutrition.protein_target_g}g)` : ""));
  }

  return lines.join("\n");
}

function human(v: string | null): string {
  if (!v) return "unset";
  return v.replace(/_/g, " ");
}

/** Every weight crossing into the prompt is converted once, here. */
export function fmtWeight(kg: number | string | null, units: "metric" | "imperial"): string {
  if (kg === null) return "—";
  const n = Number(kg);
  const v = units === "metric" ? n : n * 2.2046226218;
  return (Math.round(v * 10) / 10).toString().replace(/\.0$/, "");
}

export function toKg(value: number, units: "metric" | "imperial"): number {
  return units === "metric" ? value : value / 2.2046226218;
}

function timeAgo(iso: string): string {
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  if (mins < 60) return `${mins} min`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}
