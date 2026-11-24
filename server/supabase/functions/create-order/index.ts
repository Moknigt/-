// Edge Function "create-order" (verify JWT: ON). The app sends {target_type, target_id}; the SERVER decides the price.
// Secrets: PAYMOB_SECRET_KEY, PAYMOB_PUBLIC_KEY, PAYMOB_INTEGRATION_IDS (e.g. "123456,234567" = card + wallet integration ids),
//          PAYMOB_REDIRECT_URL (optional, shown after the payment). SUPABASE_URL / ANON / SERVICE_ROLE are provided by Supabase.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Content-Type": "application/json" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: cors });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return json({ error: "not_signed_in" }, 401);
    const uid = u.user.id;
    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: me } = await db.from("profiles").select("role,active,full_name,phone").eq("id", uid).single();
    if (!me || me.role !== "student" || !me.active) return json({ error: "students_only" }, 403);

    const { target_type, target_id } = await req.json();
    if (!["lesson", "chapter"].includes(target_type) || typeof target_id !== "string") return json({ error: "bad_target" }, 400);

    // ---- price from the table (never from the app) ----
    let type: "lesson" | "chapter" = target_type, id: string = target_id, price = 0, title = "";
    if (type === "lesson") {
      const { data: l } = await db.from("lessons").select("id,title,price,published,chapter_id").eq("id", id).single();
      if (!l || !l.published) return json({ error: "not_found" }, 404);
      let cp = 0, ct = "";
      if (l.chapter_id) { const { data: c } = await db.from("chapters").select("title,price").eq("id", l.chapter_id).single(); cp = c?.price ?? 0; ct = c?.title ?? ""; }
      if (l.price > 0) { price = l.price; title = l.title; }
      else if (cp > 0) { type = "chapter"; id = l.chapter_id; price = cp; title = ct; }   // a free-priced lesson inside a paid course is sold as the course (same as the app)
    } else {
      const { data: c } = await db.from("chapters").select("title,price").eq("id", id).single();
      if (!c) return json({ error: "not_found" }, 404);
      price = c.price; title = c.title;
    }
    if (price <= 0) return json({ error: "free_content" }, 400);

    // ---- already open? ----
    const { data: have } = await db.from("grants").select("id").eq("student", uid).eq("target_type", type).eq("target_id", id).is("revoked_at", null).limit(1);
    if (have && have.length) return json({ error: "already_open" }, 409);

    const cents = price * 100;
    const { data: order, error: oe } = await db.from("orders")
      .insert({ student: uid, target_type: type, target_id: id, amount_cents: cents }).select("id").single();
    if (oe || !order) return json({ error: "order_failed" }, 500);

    const names = (me.full_name || "Student").trim().split(/\s+/);
    const body: Record<string, unknown> = {
      amount: cents, currency: "EGP",
      payment_methods: (Deno.env.get("PAYMOB_INTEGRATION_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean).map((s) => /^\d+$/.test(s) ? Number(s) : s),
      items: [{ name: title.slice(0, 50) || "Course", amount: cents, description: title.slice(0, 100) || "Course", quantity: 1 }],
      billing_data: {
        first_name: names[0], last_name: names.slice(1).join(" ") || "NA", email: u.user.email ?? "NA",
        phone_number: me.phone || "+201000000000",   // Paymob requires a phone; this placeholder is only used when the profile has none
        apartment: "NA", floor: "NA", street: "NA", building: "NA", city: "NA", state: "NA", country: "EG", postal_code: "NA",
      },
      special_reference: order.id,
      notification_url: `${url}/functions/v1/paymob-webhook`,
    };
    const redirect = Deno.env.get("PAYMOB_REDIRECT_URL");
    if (redirect) body.redirection_url = redirect;

    const r = await fetch("https://accept.paymob.com/v1/intention/", {
      method: "POST",
      headers: { Authorization: `Token ${Deno.env.get("PAYMOB_SECRET_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const p = await r.json().catch(() => ({}));
    if (!r.ok || !p.client_secret) { await db.from("orders").update({ status: "failed" }).eq("id", order.id); return json({ error: "provider_failed" }, 502); }

    await db.from("orders").update({ provider_intention: String(p.id ?? ""), provider_order: String(p.intention_order_id ?? p.order_id ?? "") }).eq("id", order.id);
    const checkoutUrl = `https://accept.paymob.com/unifiedcheckout/?publicKey=${encodeURIComponent(Deno.env.get("PAYMOB_PUBLIC_KEY") ?? "")}&clientSecret=${encodeURIComponent(p.client_secret)}`;
    return json({ orderId: order.id, amount: price, checkoutUrl });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
