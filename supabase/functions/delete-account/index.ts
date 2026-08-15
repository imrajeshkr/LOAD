// =============================================================================
// LOAD — delete-account Edge Function
//
// Permanently deletes the CALLING user's account and everything derived from
// it. There is no target-user parameter — the id is taken only from the
// caller's own JWT, so this function can never be used to delete anyone else.
//
// Two credentials are used, deliberately kept apart:
//   caller  — built from the request's own Authorization header. Used only to
//             resolve "who is asking" via auth.getUser(). Never used to read
//             or write data (an anon/RLS client can't delete auth users, and
//             we don't need it to — the schema tells us what belongs to them).
//   admin   — service_role, used only after the caller's identity is known:
//             to remove their Storage objects (no FK ties storage to a user)
//             and to call auth.admin.deleteUser(), which cascades through
//             every table via `on delete cascade` back to profiles(id).
// =============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
      headers: { ...CORS, "content-type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "missing Authorization header" }), {
      status: 401,
      headers: { ...CORS, "content-type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Caller client: identity only, never a data path.
  const caller = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await caller.auth.getUser();
  if (userErr || !userData.user) {
    return new Response(JSON.stringify({ error: "invalid session" }), {
      status: 401,
      headers: { ...CORS, "content-type": "application/json" },
    });
  }
  const uid = userData.user.id;

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // Storage objects aren't foreign-keyed to the user, so the cascade below
  // won't touch them — remove them first while we still have their paths.
  const { data: files, error: listErr } = await admin.storage
    .from("progress-photos")
    .list(uid, { limit: 1000 });
  if (!listErr && files && files.length > 0) {
    await admin.storage
      .from("progress-photos")
      .remove(files.map((f) => `${uid}/${f.name}`));
  }

  // Cascades through every user-scoped table via profiles(id) → auth.users(id)
  // on delete cascade: sessions, sets, programs, coach threads, measurements,
  // constraints, photos rows, preferences — all of it.
  const { error: deleteErr } = await admin.auth.admin.deleteUser(uid);
  if (deleteErr) {
    return new Response(JSON.stringify({ error: deleteErr.message }), {
      status: 500,
      headers: { ...CORS, "content-type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS, "content-type": "application/json" },
  });
});
