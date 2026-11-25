// Edge Function "wa-webhook" (deploy with --no-verify-jwt; Meta calls it). The WhatsApp Cloud API webhook of the platform's number.
// GET  = Meta's one-time check: answers hub.challenge when hub.verify_token == WHATSAPP_VERIFY_TOKEN.
// POST = a message arrived. The call must carry a valid X-Hub-Signature-256 (HMAC-SHA256 of the raw body with WHATSAPP_APP_SECRET), else it is refused.
// For every text message that contains a reference (6 letters/digits from the otp-start alphabet): otp_claim() accepts it only if the SENDER number
// equals the number typed in the sign-up; then a 6-digit code is made, only its hash is stored, and the code is sent back as a normal text reply
// (inside the 24 h window opened by the student's message = no template, no charge for it). The code is never logged.
// Secrets: OTP_PEPPER (same as otp-verify), WHATSAPP_TOKEN, WHATSAPP_PHONE_ID, WHATSAPP_VERIFY_TOKEN, WHATSAPP_APP_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
async function sha256Hex(s: string) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}
function same(a: string, b: string) {          // compare without stopping at the first different character
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const newCode = () => String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
const REF = /(?<![A-Za-z0-9])[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{6}(?![A-Za-z0-9])/;

async function reply(to: string, text: string) {
  const id = Deno.env.get("WHATSAPP_PHONE_ID") ?? "";
  const token = Deno.env.get("WHATSAPP_TOKEN") ?? "";
  const r = await fetch(`https://graph.facebook.com/v21.0/${id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body: text } }),
  }).catch(() => null);
  if (!r || !r.ok) console.error("whatsapp reply failed", r?.status ?? "network");   // status only
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === (Deno.env.get("WHATSAPP_VERIFY_TOKEN") ?? "\u0000");
    return ok ? new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 }) : new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });

  const raw = await req.text();
  const secret = Deno.env.get("WHATSAPP_APP_SECRET") ?? "";
  const sig = (req.headers.get("x-hub-signature-256") ?? "").replace(/^sha256=/, "");
  if (!secret || !same(sig, await hmacHex(secret, raw))) return new Response("forbidden", { status: 403 });

  try {
    const pepper = Deno.env.get("OTP_PEPPER") ?? "";
    if (pepper.length < 16) return new Response("ok", { status: 200 });
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const body = JSON.parse(raw);
    for (const entry of body?.entry ?? []) for (const ch of entry?.changes ?? []) for (const m of ch?.value?.messages ?? []) {
      if (m?.type !== "text" || typeof m?.from !== "string") continue;
      const ref = String(m?.text?.body ?? "").match(REF)?.[0];
      if (!ref) continue;
      const code = newCode();
      const { data } = await db.rpc("otp_claim", { p_from: m.from, p_ref: ref, p_code_hash: await sha256Hex(`${pepper}:${code}`) });
      if (data?.ok) await reply(m.from, `كود التحقق بتاعك في منصة الإبداع: ${code}\nصالح 10 دقايق. ارجع للتطبيق واكتبه.\nYour verification code: ${code}`);
      else if (data?.reason === "other_number") await reply(m.from, "الرقم اللي بعت الرسالة مش هو الرقم اللي اتكتب في التسجيل. ابعت من نفس الرقم.\nThis is not the number typed in the sign-up. Send from the same number.");
      else if (data?.reason === "wa_limit") await reply(m.from, "الواتس وصل للحد الشهري. افتح التطبيق واختار تلجرام لاستلام الكود.\nWhatsApp is full this month. Open the app and choose Telegram to get your code.");
      // unknown_ref / already / wrong_channel: no answer (nothing to tell, and it gives no hint to guessers)
    }
  } catch (_e) { /* Meta must always get 200, or it retries the same message */ }
  return new Response("ok", { status: 200 });
});
