// =============================================================================
// Gemini provider adapter — the only file that knows which vendor we're on.
//
// Uses the REST `generateContent` surface directly rather than an SDK: it keeps
// the Deno bundle small, avoids SDK/Deno compatibility drift, and this is the
// surface that supports context caching.
//
// Vendor-shaped details worth knowing if you swap this out:
//   * `contents` roles are only "user" and "model" — there is no system role.
//     The system prompt is a separate top-level `systemInstruction` field.
//   * Tool results go back as a "user" turn containing `functionResponse`
//     parts, and `response` must be an object (scalars need wrapping).
//   * On Gemini 3.x the model turn may carry `thoughtSignature` parts that
//     must be echoed back verbatim. We replay the whole `parts` array, so
//     that happens for free — do not filter parts when rebuilding history.
// =============================================================================

const API_ROOT = "https://generativelanguage.googleapis.com/v1beta";

/** Pinned deliberately. Provider defaults move, and a coach whose behaviour
 *  shifts under you is very hard to debug. */
export const MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.6-flash";

export interface Part {
  text?: string;
  functionCall?: { id?: string; name: string; args: Record<string, unknown> };
  functionResponse?: { id?: string; name: string; response: Record<string, unknown> };
  thought?: boolean;
  thoughtSignature?: string;
}

export interface Content {
  role: "user" | "model";
  parts: Part[];
}

export interface FunctionDeclaration {
  name: string;
  description: string;
  // OpenAPI subset. Note: `additionalProperties` is NOT reliably honoured
  // here, so it is omitted throughout — validate server-side instead.
  parameters: Record<string, unknown>;
}

export interface GenerateResult {
  content: Content | null;
  text: string;
  functionCalls: NonNullable<Part["functionCall"]>[];
  finishReason: string | null;
  blocked: boolean;
  blockReason: string | null;
  usage: { promptTokens: number; cachedTokens: number; outputTokens: number };
}

export class GeminiError extends Error {
  constructor(message: string, readonly status: number, readonly body: string) {
    super(message);
  }
}

export async function generate(opts: {
  systemInstruction: string;
  contents: Content[];
  tools?: FunctionDeclaration[];
  maxOutputTokens?: number;
  /** "minimal" | "low" | "medium" | "high" — the portable reasoning dial. */
  thinkingLevel?: string;
  signal?: AbortSignal;
}): Promise<GenerateResult> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY is not set on the function");

  const body: Record<string, unknown> = {
    systemInstruction: { parts: [{ text: opts.systemInstruction }] },
    contents: opts.contents,
    generationConfig: {
      maxOutputTokens: opts.maxOutputTokens ?? 1400,
      thinkingConfig: { thinkingLevel: opts.thinkingLevel ?? "low" },
    },
  };

  if (opts.tools?.length) {
    body.tools = [{ functionDeclarations: opts.tools }];
    body.toolConfig = { functionCallingConfig: { mode: "AUTO" } };
  }

  const res = await fetch(`${API_ROOT}/models/${MODEL}:generateContent`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
    body: JSON.stringify(body),
    signal: opts.signal,
  });

  const raw = await res.text();
  if (!res.ok) {
    throw new GeminiError(`Gemini ${res.status}`, res.status, raw.slice(0, 600));
  }

  // deno-lint-ignore no-explicit-any
  const json: any = JSON.parse(raw);

  // A blocked prompt comes back 200 with no candidates at all. Reading
  // candidates[0] unconditionally is the classic way to crash here.
  const blockReason: string | null = json?.promptFeedback?.blockReason ?? null;
  const candidate = json?.candidates?.[0] ?? null;

  if (!candidate) {
    return {
      content: null,
      text: "",
      functionCalls: [],
      finishReason: null,
      blocked: true,
      blockReason: blockReason ?? "NO_CANDIDATES",
      usage: readUsage(json),
    };
  }

  const parts: Part[] = candidate?.content?.parts ?? [];
  const finishReason: string | null = candidate?.finishReason ?? null;

  return {
    content: candidate.content ?? null,
    // Thought-summary parts are marked `thought: true` and are not the answer.
    text: parts.filter((p) => p.text && !p.thought).map((p) => p.text).join(""),
    functionCalls: parts.flatMap((p) => (p.functionCall ? [p.functionCall] : [])),
    finishReason,
    // Anything other than STOP/MAX_TOKENS is abnormal. The enum is open, so
    // this treats unknown values as abnormal rather than switching on a list.
    blocked: finishReason !== null && !["STOP", "MAX_TOKENS"].includes(finishReason),
    blockReason,
    usage: readUsage(json),
  };
}

// deno-lint-ignore no-explicit-any
function readUsage(json: any) {
  const u = json?.usageMetadata ?? {};
  return {
    promptTokens: u.promptTokenCount ?? 0,
    cachedTokens: u.cachedContentTokenCount ?? 0,
    outputTokens: u.candidatesTokenCount ?? 0,
  };
}
