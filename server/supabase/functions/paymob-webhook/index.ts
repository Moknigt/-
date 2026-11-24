// Edge Function "paymob-webhook" (verify JWT: OFF, because Paymob calls it: deploy with --no-verify-jwt).
// Secrets: PAYMOB_HMAC_SECRET. Paymob posts {type:"TRANSACTION", obj:{...}} and puts the signature in ?hmac=
// Signature = HMAC-SHA512 (hex) of 20 fields of obj joined with no separator, in this exact order.
import { createClient } from "npm:@supabase/supabase-js@2";

const FIELDS = ["amount_cents", "created_at", "currency", "error_occured", "has_parent_transaction", "id", "integration_id", "is_3d_secure",
  "is_auth", "is_capture", "is_refunded", "is_standalone_payment", "is_voided", "order.id", "owner", "pending",
  "source_data.pan", "source_data.sub_type", "source_data.type", "success"];

// deno-lint-ignore no-explicit-any
const pick = (o: any, path: string) => path.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);

async function hmacHex(secret: string, msg: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)));
  return [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) {          // constant time
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const secret = Deno.env.get("PAYMOB_HMAC_SECRET");
  if (!secret) return new Response("not configured", { status: 500 });
  const given = (new URL(req.url).searchParams.get("hmac") ?? "").toLowerCase();
  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return new Response("bad body", { status: 400 }); }
  if (body?.type !== "TRANSACTION" || !body.obj) return new Response("ignored");      // card-token and other callbacks

  const obj = body.obj;
  const msg = FIELDS.map((f) => String(pick(obj, f) ?? "")).join("");
  if (!given || !same(await hmacHex(secret, msg), given)) return new Response("bad signature", { status: 401 });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const ref = String(obj.order?.merchant_order_id ?? obj.merchant_order_id ?? "");   // = our orders.id (special_reference)
  if (!/^[0-9a-f-]{36}$/i.test(ref)) return new Response("no reference");
  const { data: order } = await db.from("orders").select("id,amount_cents,currency,status").eq("id", ref).single();
  if (!order) return new Response("unknown order");
  const tx = String(obj.id ?? "");

  if (obj.is_refunded === true || obj.is_voided === true) {
    await db.rpc("refund_order", { p_order: ref, p_tx: tx });
  } else if (obj.success === true && obj.pending === false) {
    if (Number(obj.amount_cents) < order.amount_cents || String(obj.currency) !== order.currency) await db.rpc("mark_order", { p_order: ref, p_status: "mismatch" });
    else await db.rpc("fulfill_order", { p_order: ref, p_tx: tx });
  } else if (obj.pending === false && obj.success === false) {
    await db.rpc("mark_order", { p_order: ref, p_status: "failed" });
  }
  return new Response("ok");     // 200 after a valid signature, so Paymob does not keep retrying
});
