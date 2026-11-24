# Platform server contract (skeleton - release 36)
Not built yet. This is what the apps (Android / iPhone / Windows) will call. Same on all three.
Rule: the server is the ONLY place that decides access. The app never trusts itself.

## Auth
Bearer token per user (student / teacher). TODO: sign-in endpoint + token refresh.

## Content (teacher only writes)
POST   /videos            {source:"yt"|"up", ytId?, title, price, chapterId?}   -> {id}
POST   /videos/{id}/file  resumable upload (tus / S3 multipart). TODO: progress + resume
DELETE /videos/{id}       teacher owner only. The ONLY way a video or its link disappears.
PUT    /videos/{id}/price {price}  (0 = free)      PUT /courses/{id}/price {price}
Links are permanent: no expiry field, no signed-URL TTL shown to users.
TODO: stream through a protected endpoint that checks the grant on every request
      (never hand out the raw YouTube id / file URL to a student without a grant).

## Access (replaces local Access.canView / canView)
GET /access?lesson={id}   -> {allowed:bool, reason:"free"|"granted"|"locked", price}
GET /lessons/{id}/play    -> 200 {ytId | streamUrl}  or  403 (locked). Server-side lock lives HERE.

## Grants (written by the server only)
POST   /grants   teacher: {student, target:"l:<id>"|"c:<id>", mode:"cash"|"free"}  -> logs who/for whom/when
DELETE /grants/{id}  teacher revoke (log line is kept)
GET    /grants/log   teacher: permanent log

## Electronic payment (ONE provider, chosen later: e-wallet or gateway)
POST /orders   {target, student} -> {orderId, amount, checkoutUrl}
POST /webhooks/payment   provider -> server. Verify the signature, then write grant mode "online".
GET  /orders/{id}        app polls until "paid", then re-asks /access and opens the content.
The screen saying "paid" is never proof.

## Release 37 - step 1 (Supabase) is written: server/supabase/001_accounts.sql
The generic routes above became Supabase calls (all through the signed-in user's token, so Postgres row level security does the locking):
- sign-in / sign-up: Supabase Auth (`/auth/v1/token`, `/auth/v1/signup`). New users are always students; the role is never taken from the app.
- `rpc/claim_teacher(p_code)`: teacher registration code, each code works once on any device (codes live in table `teacher_codes`, added from the Supabase dashboard).
- `rpc/access_lesson(p_lesson)` -> {allowed, reason, price}; `rpc/play_source(p_lesson)` -> source, or error 42501 when locked.
- `rpc/teacher_grant(student, type, target, mode)` (cash / free) and `rpc/teacher_revoke(grant)`; every action is appended to `grant_log` (nobody can edit it).
- Delete a video: `DELETE /rest/v1/lessons?id=eq.<id>`; only the owner teacher passes the policy.
- Still to write: step 2 = 002_payments.sql (orders + Paymob webhook as an Edge Function, writes grants with mode "online"); step 3 = 003_storages.sql (list of R2 storages with a 9 GB limit each, upload route, delete-file queue).

## Release 38 - step 2 (Paymob) is written: server/supabase/002_payments.sql + functions/ + PAYMENTS_SETUP.md
- `POST /functions/v1/create-order` {target_type, target_id} -> {orderId, amount, checkoutUrl}. The server takes the price from the tables (a free-priced lesson inside a paid course is sold as the course), refuses if already open (409), creates the order, calls Paymob `POST /v1/intention/` with the secret key and returns the Unified Checkout link.
- `POST /functions/v1/paymob-webhook?hmac=...` (Paymob -> server): checks the HMAC-SHA512 of 20 fields, then `fulfill_order` (grant mode "online" + log line, idempotent), `refund_order` (closes the online grant) or `mark_order` (failed / amount mismatch).
- `rpc/order_status(p_order)` -> pending / paid / failed / refunded / mismatch / missing (the app polls it, then asks `access_lesson` again).

## Release 39 - step 3, part 1 (storages) is written: server/supabase/003_storages.sql (+ test_003.sql, test_003_race.sh) - NOT run yet
R2 has no spending cap, so the limit is ours and lives on the server: 8 GiB per storage, 8 GiB per Cloudflare account, 1 GiB per file. Space is reserved before an upload link exists, checked again with the real size after the upload, and only released after R2 confirmed a delete.
- `reserve_upload` / `complete_upload` / `release_upload` / `queue_next` / `queue_done` / `queue_fail` / `reconcile_storage` / `expire_reservations` / `storage_prune`: service_role only (they are called by the Edge Functions of part 2: upload-url, upload-complete, play-url, purge-deleted).
- The apps only read `rest/v1/storages` (safe columns: id, name, limit_bytes, used_bytes, reserved_bytes, active, sort_order); the admin may edit name, limit (never above 8 GiB), active, sort_order. No key, endpoint or bucket name reaches the app.
- Still to write: part 2 (Edge Functions), part 3 (apps: Remote.uploadVideo / playUrl + Storage screen), part 4 (STORAGES_SETUP.md).

