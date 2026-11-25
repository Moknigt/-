// Edge Function "otp-verify" (deploy with --no-verify-jwt). Body: {phone, code}.
// Right code -> {ok:true, token}: a one-time token the app puts in the sign-up (user metadata "phone_token"); handle_new_user() checks and uses it up.
// Wrong / old code -> {ok:false, reason: wrong | expired | locked | waiting}  (waiting = the student's WhatsApp message did not arrive yet). Same OTP_PEPPER secret as wa-webhook.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Content-Type": "application/json" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: cors });

async function sha256Hex(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const pepper = Deno.env.get("OTP_PEPPER") ?? "";
    if (pepper.length < 16) return json({ error: "not_configured" }, 503);
    const body = await req.json().catch(() => ({}));
    if (typeof body?.phone !== "string" || body.phone.length > 40 || typeof body?.code !== "string" || !/^[0-9]{6}$/.test(body.code)) {
      return json({ error: "bad_request" }, 400);
    }
    const token = [...crypto.getRandomValues(new Uint8Array(32))].map((x) => x.toString(16).padStart(2, "0")).join("");
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data, error } = await db.rpc("otp_check", {
      p_phone: body.phone,
      p_code_hash: await sha256Hex(`${pepper}:${body.code}`),
      p_token_hash: await sha256Hex(token),
    });
    if (error || !data) return json({ error: "server_error" }, 500);
    return data.ok ? json({ ok: true, token }) : json({ ok: false, reason: data.reason });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
