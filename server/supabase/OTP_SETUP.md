# Phone check on WhatsApp - student writes FIRST (release 64)

How it works (no paid template message is ever sent):
1. The student types his number and taps sign-up. The app asks `otp-start` for a short reference.
2. The app opens WhatsApp with a ready message (to the platform number) that contains the reference. The student taps send.
3. Meta calls `wa-webhook`. The server accepts the message ONLY if the sender number is the number typed in the sign-up, then answers in the same chat with a 6-digit code (a normal reply inside the 24 h window opened by the student = not a template).
4. The student comes back to the app, types the code, `otp-verify` checks it, and the account is made.
Nothing secret is inside the app; only a hash of the code is stored.

## 1. WhatsApp Cloud API (Meta) - once
1. developers.facebook.com -> create an app (type Business) -> add the product "WhatsApp".
2. Add the platform's WhatsApp number. Copy its **Phone number ID**; keep the number itself (digits, with country code, e.g. 2010xxxxxxxx).
3. Create a **permanent access token** (Business settings -> System users, permission `whatsapp_business_messaging`).
4. From App settings -> Basic copy the **App secret**.
5. WhatsApp -> Configuration -> Webhook: Callback URL = `https://<your-project>.supabase.co/functions/v1/wa-webhook`, Verify token = any long text you choose (same as `WHATSAPP_VERIFY_TOKEN` below). Press Verify, then Subscribe to the field **messages**.
No message template is needed.

## 2. Supabase
1. SQL Editor -> run `007_phone_otp.sql` once (after 006).
2. Secrets (Project settings -> Edge Functions -> Secrets, or `supabase secrets set ...`):
   - `OTP_PEPPER` = long random text, at least 16 characters (secret)
   - `WHATSAPP_TOKEN` = the permanent token
   - `WHATSAPP_PHONE_ID` = the Phone number ID
   - `WHATSAPP_BUSINESS_NUMBER` = the platform number, digits only (the app opens a chat with it)
   - `WHATSAPP_VERIFY_TOKEN` = the text you typed in the webhook screen
   - `WHATSAPP_APP_SECRET` = the App secret
3. Deploy all three WITHOUT jwt check (the user has no account yet / Meta has no token):
   `supabase functions deploy otp-start --no-verify-jwt`
   `supabase functions deploy otp-verify --no-verify-jwt`
   `supabase functions deploy wa-webhook --no-verify-jwt`

## 3. Test
Sign up as a student in the Android app with your own number: WhatsApp opens with the ready message, send it, the code comes back in the chat, type it in the app. Also test: send the message from ANOTHER number (must get "not the same number", no code), and a wrong code (boxes shake).

## 4. Money
The reply with the code is a normal (service) message after the student wrote first, so no template is charged. Meta may change its rules; check the pricing page of your business account if you see charges. While the app is in development mode Meta only lets numbers you added as testers write to the number; go live (business verification) before real students use it.

## 5. The gate (later)
Until the iPhone and Windows apps ask for the code too, leave `app_settings.require_phone_otp = 'false'`. When all apps are ready:
`update public.app_settings set value = 'true' where key = 'require_phone_otp';`
Then the server refuses any sign-up that has a phone but no verified token. (A sign-up sent with NO phone at all is not refused; admin accounts have none.)

Known limit: some countries write the WhatsApp number differently from the normal one (e.g. Mexico, Argentina); there the sender may not match and the student gets "not the same number". Egyptian numbers match.

## 6. Telegram + WhatsApp cap (release 77, step 1 of 4)
1. SQL Editor -> run `008_otp_channel.sql` once (after 007). It adds the channel (`tg` / `wa`) and a WhatsApp counter per month (Cairo calendar month). The cap is `app_settings.wa_monthly_limit` (default 1000); change it with `update public.app_settings set value = '1000' where key = 'wa_monthly_limit';`
2. Redeploy the two functions that changed (still without jwt check): `supabase functions deploy otp-start --no-verify-jwt` and `supabase functions deploy wa-webhook --no-verify-jwt`.
3. Only real WhatsApp replies are counted (when the code is sent). When the month is full: `otp-start` answers `wa_limit` for channel `wa`, and `wa-webhook` tells the student to use Telegram. Telegram has no cap.
4. See the month: `select * from public.otp_wa_usage order by month desc;`
5. Not yet working: the Telegram bot itself (step 2) and the apps asking for channel `tg` (step 3). Until then everything behaves as before. The secret `TELEGRAM_BOT_USERNAME` is only needed from step 2 on.

## 7. Telegram bot - what YOU do (release 78, written ahead of the bot code)
The bot function `tg-webhook` and the apps are NOT written yet (steps 2 and 3). This section is the checklist for step 4, so you can prepare in advance. Nothing here breaks the current WhatsApp flow.
1. **Create the bot**: in Telegram open @BotFather -> `/newbot` -> choose a name and a username that ends with `bot` (5 to 32 letters, digits or `_`). Copy the **token** it gives you (secret: anyone with it controls the bot).
2. **Supabase secrets** (Project settings -> Edge Functions -> Secrets, or `supabase secrets set ...`):
   - `TELEGRAM_BOT_TOKEN` = the token from BotFather (secret)
   - `TELEGRAM_BOT_USERNAME` = the bot username WITHOUT the `@` (the apps open `t.me/<username>?start=<ref>`; `otp-start` already reads this one)
   - `TELEGRAM_WEBHOOK_SECRET` = a long random text, 16 to 64 characters, only letters, digits, `_` and `-` (Telegram allows nothing else)
3. **Deploy** (without jwt check, Telegram has no token): `supabase functions deploy tg-webhook --no-verify-jwt` (after the function exists, step 2).
4. **Webhook** (once, after the deploy; replace the three values; do not paste the token anywhere public):
   `curl "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/setWebhook" -d "url=https://<your-project>.supabase.co/functions/v1/tg-webhook" -d "secret_token=<TELEGRAM_WEBHOOK_SECRET>" -d "allowed_updates=[\"message\"]"`
   Check it: `curl "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getWebhookInfo"` (url set, no `last_error_message`).
5. **Tests** (real phones): Telegram installed; Telegram NOT installed (the app must fall back to WhatsApp); the WhatsApp cap reached (for the test set `update public.app_settings set value = '2' where key = 'wa_monthly_limit';` then put it back to `1000`); a wrong number; a contact of ANOTHER person sent to the bot (must be refused).
Telegram costs nothing and has no monthly cap.
