// Edge Function "otp-start" (deploy with --no-verify-jwt: the user has no account yet). Body: {phone, channel?}  channel = "tg" | "wa" (default "wa", so old apps keep working).
// Makes a short REFERENCE (not the code) and remembers it for this phone (otp_start: 55 s between requests, 5 per hour per phone, 20 per hour per IP).
// Answer for wa: {ok:true, channel:"wa", ref, wa}  wa = the platform's WhatsApp number (digits). The STUDENT sends the ref there; wa-webhook answers with the code.
// Answer for tg: {ok:true, channel:"tg", ref, tg}  tg = the bot's username (no @). The app opens t.me/<tg>?start=<ref>; the bot asks for the contact and answers with the code.
// Errors: bad_phone | bad_channel | too_soon | limit | wa_limit (WhatsApp month is full: tell the student to use Telegram) | not_configured.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Content-Type": "application/json" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: cors });
const STATUS: Record<string, number> = { bad_phone: 400, bad_channel: 400, too_soon: 429, limit: 429, wa_limit: 429 };
const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";   // no I, L, O, 0, 1 (the webhook looks for exactly this alphabet)

function newRef() {
  const b = crypto.getRandomValues(new Uint8Array(6));
  return [...b].map((x) => ALPHABET[x % ALPHABET.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    if (typeof body?.phone !== "string" || body.phone.length > 40) return json({ error: "bad_phone" }, 400);
    const channel = body?.channel === undefined ? "wa" : body.channel;
    if (channel !== "wa" && channel !== "tg") return json({ error: "bad_channel" }, 400);

    const wa = (Deno.env.get("WHATSAPP_BUSINESS_NUMBER") ?? "").replace(/[^0-9]/g, "");
    const tg = (Deno.env.get("TELEGRAM_BOT_USERNAME") ?? "").replace(/^@/, "").trim();
    if (channel === "wa" && wa.length < 8) return json({ error: "not_configured" }, 503);
    if (channel === "tg" && !/^[A-Za-z0-9_]{5,32}$/.test(tg)) return json({ error: "not_configured" }, 503);

    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim().slice(0, 64);
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const ref = newRef();
    const { data, error } = await db.rpc("otp_start", { p_phone: body.phone, p_ref: ref, p_ip: ip, p_channel: channel });
    if (error || !data) return json({ error: "server_error" }, 500);
    if (!data.ok) return json({ error: data.reason }, STATUS[data.reason] ?? 400);
    return json(channel === "tg" ? { ok: true, channel, ref, tg } : { ok: true, channel, ref, wa });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
