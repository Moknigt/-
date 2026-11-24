// Edge Function "purge-deleted" (SCHEDULED, verify JWT: OFF: deploy with --no-verify-jwt). Called by pg_cron / Supabase Cron, e.g. every 15 minutes.
// Protected by its own secret: the caller must send the header  x-purge-secret: <PURGE_SECRET>  (secret set in Edge Function secrets).
// What it does, in this order (the order matters):
//   1. expire_reservations()          : uploads never finished give their space back.
//   2. delete queue                   : delete each queued object in R2 (404 = already gone = success) THEN queue_done (space comes back only after R2 confirmed);
//                                       a failure goes to queue_fail (10 failures = dead: it keeps counting, never forgotten silently).
//   3. per storage: list the bucket   : the REAL total. Orphans (objects under v/ that the database does not know and that are older than 3 hours) are deleted,
//                                       then reconcile_storage(storage, real total) compares with our counter and switches the storage OFF if they disagree or it is nearly full.
//                                       If the listing fails, that storage is skipped: a partial list is NEVER reported as the real size.
//   4. storage_prune()                : old finished rows go (the free database is small).
// Answer: counts only. Keys, URLs and object names are never returned or logged.
import { createClient } from "npm:@supabase/supabase-js@2";
import { credsFor, cors, deleteObject, json, listAll } from "../_shared/r2.ts";

const ORPHAN_AGE_MS = 3 * 3600 * 1000;     // > upload link (1 h) + reservation (2 h)
const MAX_QUEUE_ITEMS = 100;               // per run (the schedule repeats)
const MAX_ORPHANS = 50;                    // per storage per run
const BUDGET_MS = 100_000;                 // stop starting new work after ~100 s

function same(a: string, b: string) {      // constant time
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const t0 = Date.now();
  const left = () => BUDGET_MS - (Date.now() - t0);
  try {
    const secret = Deno.env.get("PURGE_SECRET") ?? "";
    const given = req.headers.get("x-purge-secret") ?? "";
    if (secret.length < 16 || !same(secret, given)) return json({ error: "forbidden" }, 403);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    // deno-lint-ignore no-explicit-any
    const storages = new Map<string, any>();
    const storeOf = async (id: string) => {
      if (!storages.has(id)) {
        const { data } = await db.from("storages").select("id,endpoint,bucket,secret_name").eq("id", id).maybeSingle();
        storages.set(id, data ?? null);
      }
      return storages.get(id);
    };
    const out = { expired: 0, deleted: 0, failed: 0, orphans: 0, reconciled: 0, skipped: 0, deactivated: 0, dead: 0 };

    // 1) expire
    const { data: ex } = await db.rpc("expire_reservations");
    out.expired = typeof ex === "number" ? ex : 0;

    // 2) delete queue
    let handled = 0;
    while (handled < MAX_QUEUE_ITEMS && left() > 0) {
      const { data: batch } = await db.rpc("queue_next", { p_limit: 20 });
      if (!batch || !batch.length) break;
      let progress = false;
      for (const q of batch) {
        if (left() <= 0) break;
        handled++;
        const st = await storeOf(q.storage_id);
        const creds = st ? credsFor(st.secret_name) : null;
        if (!st || !creds) { await db.rpc("queue_fail", { p_id: q.id, p_error: "storage_not_configured" }); out.failed++; continue; }
        try {
          await deleteObject(st, creds, q.storage_key);
          await db.rpc("queue_done", { p_id: q.id });          // the space comes back only now
          out.deleted++; progress = true;
        } catch (e) {
          await db.rpc("queue_fail", { p_id: q.id, p_error: String((e as Error).message ?? "error").slice(0, 100) });   // error code only, never a URL
          out.failed++;
        }
      }
      if (!progress) break;                                      // everything failed: do not spin on the same rows
    }

    // 3) real size per storage + orphans + reconcile
    const { data: all } = await db.from("storages").select("id,endpoint,bucket,secret_name").order("sort_order");
    for (const st of all ?? []) {
      if (left() <= 0) { out.skipped++; continue; }
      const creds = credsFor(st.secret_name);
      if (!creds) { out.skipped++; continue; }
      try {
        const objects = await listAll(st, creds);
        // keys the database knows (paged)
        const known = new Set<string>();
        for (let from = 0; ; from += 1000) {
          const { data: rows, error } = await db.from("stored_files").select("storage_key").eq("storage_id", st.id).order("storage_key").range(from, from + 999);
          if (error) throw new Error("db_read");
          for (const r of rows ?? []) known.add(r.storage_key);
          if (!rows || rows.length < 1000) break;
        }
        let total = objects.reduce((s, o) => s + o.size, 0);
        let swept = 0;
        for (const o of objects) {
          if (swept >= MAX_ORPHANS || left() <= 0) break;
          if (known.has(o.key) || !o.key.startsWith("v/") || o.modified === 0 || Date.now() - o.modified < ORPHAN_AGE_MS) continue;
          try { await deleteObject(st, creds, o.key); total -= o.size; swept++; out.orphans++; } catch (_e) { /* stays counted; tried again next run */ }
        }
        const { data: rec } = await db.rpc("reconcile_storage", { p_storage: st.id, p_actual_bytes: total });
        out.reconciled++;
        if (rec?.deactivated || rec?.accountDeactivated) out.deactivated++;
      } catch (_e) { out.skipped++; }                            // listing failed: never reconcile with a partial number
    }

    // 4) housekeeping
    await db.rpc("storage_prune");
    const { count } = await db.from("file_delete_queue").select("id", { count: "exact", head: true }).eq("status", "dead");
    out.dead = count ?? 0;
    return json({ ok: true, ...out, ms: Date.now() - t0 });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
