// Edge Function "play-url" (verify JWT: ON). Body: {lessonId}.
// 1) The decision is made by Postgres through the USER'S OWN token: play_source() calls can_view_lesson() and raises 42501 when the lesson is locked.
// 2) Only then the server signs a short presigned GET for the stored file. The video itself is permanent; only this link is renewed every time.
// Answer: {src:"up", url, expiresIn}  or  {src:"yt", ytId}  or  {error:"locked"} (403).
// A storage switched OFF (active = false) still plays: "off" only stops new uploads.
import { createClient } from "npm:@supabase/supabase-js@2";
import { credsFor, cors, isUuid, json, PLAY_TTL_SECONDS, presign } from "../_shared/r2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return json({ error: "not_signed_in" }, 401);

    const body = await req.json().catch(() => ({}));
    if (!isUuid(body?.lessonId)) return json({ error: "bad_lesson" }, 400);

    const { data: src, error } = await asUser.rpc("play_source", { p_lesson: body.lessonId });   // the ONE lock decision (can_view_lesson)
    if (error) return json({ error: error.code === "42501" ? "locked" : "server_error" }, error.code === "42501" ? 403 : 500);
    if (!src) return json({ error: "not_found" }, 404);

    if (src.src !== "up") return json({ src: "yt", ytId: src.ytId ?? "" });
    if (!src.storageId || !src.storageKey) return json({ error: "no_file" }, 404);            // the lesson has no uploaded file yet

    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: st } = await db.from("storages").select("endpoint,bucket,secret_name").eq("id", src.storageId).maybeSingle();
    const creds = st ? credsFor(st.secret_name) : null;
    if (!st || !creds) return json({ error: "storage_not_configured" }, 503);

    const link = await presign(st, creds, "GET", src.storageKey, PLAY_TTL_SECONDS);
    return json({ src: "up", url: link, expiresIn: PLAY_TTL_SECONDS });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
