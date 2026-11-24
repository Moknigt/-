// Edge Function "upload-url" (verify JWT: ON). Teacher / admin asks for a direct-to-R2 upload link for ONE lesson video.
// Body: {lessonId, sizeBytes, ext?}.  Answer: {reservationId, uploadUrl, method:"PUT", expiresIn, sizeBytes}  or  {error: <reason>} (+ maxBytes when too_large).
// The teacher id comes from the VERIFIED JWT, never from the body. The space is reserved in Postgres BEFORE any link exists.
// The link is a presigned PUT with a SIGNED Content-Length = the reserved size and a lifetime <= 1 hour: R2 itself refuses any other size.
// Secrets: <secret_name>_ACCESS_KEY_ID / <secret_name>_SECRET_ACCESS_KEY per storage (see STORAGES_SETUP.md). SUPABASE_* are provided by Supabase.
import { createClient } from "npm:@supabase/supabase-js@2";
import { credsFor, cors, isUuid, json, MAX_FILE_BYTES, presign, REASON_STATUS, UPLOAD_TTL_SECONDS } from "../_shared/r2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return json({ error: "not_signed_in" }, 401);
    const uid = u.user.id;                       // the ONLY source of the owner
    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const body = await req.json().catch(() => ({}));
    const lessonId = body?.lessonId, size = body?.sizeBytes;
    if (!isUuid(lessonId)) return json({ error: "bad_lesson" }, 400);
    if (typeof size !== "number" || !Number.isSafeInteger(size) || size <= 0) return json({ error: "bad_size" }, 400);
    if (size > MAX_FILE_BYTES) return json({ error: "too_large", maxBytes: MAX_FILE_BYTES }, 413);   // fast refusal; the database checks again
    const ext = typeof body?.ext === "string" ? body.ext : "mp4";

    const { data: r, error } = await db.rpc("reserve_upload", { p_owner: uid, p_lesson: lessonId, p_size: size, p_ext: ext });
    if (error || !r) return json({ error: "server_error" }, 500);
    if (!r.ok) return json({ error: r.reason, ...(r.maxBytes ? { maxBytes: r.maxBytes } : {}) }, REASON_STATUS[r.reason as string] ?? 400);

    // from here on the space is reserved: if we cannot hand out a link, give it back at once
    const creds = credsFor(r.secretName);
    if (!creds) { await db.rpc("release_upload", { p_owner: uid, p_reservation: r.reservationId }); return json({ error: "storage_not_configured" }, 503); }
    let uploadUrl: string;
    try {
      uploadUrl = await presign({ endpoint: r.endpoint, bucket: r.bucket, secret_name: r.secretName }, creds, "PUT", r.key, UPLOAD_TTL_SECONDS, { contentLength: r.sizeBytes });
    } catch (_e) {
      await db.rpc("release_upload", { p_owner: uid, p_reservation: r.reservationId });
      return json({ error: "server_error" }, 500);
    }
    return json({ reservationId: r.reservationId, uploadUrl, method: "PUT", expiresIn: UPLOAD_TTL_SECONDS, sizeBytes: r.sizeBytes });
  } catch (_e) {
    return json({ error: "server_error" }, 500);   // nothing is logged: URLs and keys must never reach the logs
  }
});
