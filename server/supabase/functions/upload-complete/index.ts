// Edge Function "upload-complete" (verify JWT: ON). Called by the app after the PUT to R2 finished (or to CANCEL).
// Body: {reservationId}  -> finish.   {reservationId, cancel:true} -> cancel.
// Finish: HEAD on the object, the REAL size goes to complete_upload (null = no object). The database decides:
//   ok -> the file is counted and attached to the lesson. Rejected (too big / expired / lesson deleted) -> the object is deleted here at once
//   (it is already counted and queued in the database, so if this delete fails purge-deleted does it later and the space stays counted).
// Cancel: delete the object if the PUT already landed, then give the reserved space back. If a PUT still lands afterwards (its link lives up to 1 hour),
//   purge-deleted finds the orphan and removes it, and reconcile_storage corrects the counter.
// The teacher id comes from the VERIFIED JWT. Nothing is logged.
import { createClient } from "npm:@supabase/supabase-js@2";
import { credsFor, cors, deleteObject, headSize, isUuid, json, REASON_STATUS } from "../_shared/r2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return json({ error: "not_signed_in" }, 401);
    const uid = u.user.id;
    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const body = await req.json().catch(() => ({}));
    const rid = body?.reservationId;
    if (!isUuid(rid)) return json({ error: "bad_reservation" }, 400);

    // the reservation must be HIS (a stranger gets the same answer as a missing one)
    const { data: res } = await db.from("upload_reservations").select("owner,storage_id,storage_key,status").eq("id", rid).maybeSingle();
    if (!res || res.owner !== uid) return json({ error: "missing" }, 404);
    const { data: st } = await db.from("storages").select("endpoint,bucket,secret_name").eq("id", res.storage_id).maybeSingle();
    const creds = st ? credsFor(st.secret_name) : null;
    if (!st || !creds) return json({ error: "storage_not_configured" }, 503);

    // ---------------- cancel ----------------
    if (body?.cancel === true) {
      if (res.status !== "reserved") return json({ ok: true, already: true });      // finished or released before: nothing to give back
      try { await deleteObject(st, creds, res.storage_key); } catch (_e) { /* an orphan is swept by purge-deleted */ }
      await db.rpc("release_upload", { p_owner: uid, p_reservation: rid });
      return json({ ok: true, cancelled: true });
    }

    // ---------------- finish ----------------
    let actual: number | null;
    try { actual = await headSize(st, creds, res.storage_key); }
    catch (_e) { return json({ error: "storage_unreachable" }, 502); }               // the app may simply retry: nothing was changed

    const { data: r, error } = await db.rpc("complete_upload", { p_owner: uid, p_reservation: rid, p_actual_bytes: actual });
    if (error || !r) return json({ error: "server_error" }, 500);

    if (r.ok) return json({ ok: true, sizeBytes: r.sizeBytes ?? actual, ...(r.already ? { already: true } : {}) });

    if (r.deleteObject) {
      // best effort, right now. Only when R2 confirms (or says 404) the queue row is closed and the space comes back.
      try {
        await deleteObject(st, creds, res.storage_key);
        const { data: q } = await db.from("file_delete_queue").select("id").eq("storage_id", res.storage_id).eq("storage_key", res.storage_key).eq("status", "pending").maybeSingle();
        if (q) await db.rpc("queue_done", { p_id: q.id });
      } catch (_e) { /* purge-deleted will do it */ }
    }
    return json({ error: r.reason }, REASON_STATUS[r.reason as string] ?? 400);
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
