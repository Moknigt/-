# Step 2 setup - Paymob (needs the owner, about 20 minutes)
1. Paymob dashboard (Egypt): get the SECRET key, PUBLIC key and HMAC secret, and the Integration IDs of the payment methods you want (card, mobile wallet). Start in TEST mode: test keys and test integration ids go together.
2. Supabase -> SQL Editor: run `002_payments.sql` (after 001).
3. Supabase -> Edge Functions: create two functions with the code in `functions/create-order/index.ts` and `functions/paymob-webhook/index.ts`.
   - `create-order`: leave "Verify JWT" ON.
   - `paymob-webhook`: turn "Verify JWT" OFF (Paymob calls it; the HMAC signature protects it). With the CLI: `supabase functions deploy paymob-webhook --no-verify-jwt`.
4. Supabase -> Edge Functions -> Secrets: `PAYMOB_SECRET_KEY`, `PAYMOB_PUBLIC_KEY`, `PAYMOB_HMAC_SECRET`, `PAYMOB_INTEGRATION_IDS` (comma separated, e.g. `123456,234567`), optional `PAYMOB_REDIRECT_URL`. The keys live ONLY here, never in the apps.
5. Test with ONE test payment before real money: pay a test course, then check that `orders.status` becomes `paid`, a row with mode `online` appears in `grants` and `grant_log`, and `access_lesson` says allowed.
   Things to confirm in that first test (written from Paymob's docs, not run against Paymob): (a) the field that carries our `special_reference` in the callback (`obj.order.merchant_order_id`); (b) that the HMAC check passes (if every callback gets 401, compare the 20-field order with Paymob's "HMAC Transaction Callback" page).
