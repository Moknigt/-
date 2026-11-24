# Step 3 setup - video storage on Cloudflare R2 (needs the owner, about 45 minutes)

> **WARNING / تحذير**
> - Cloudflare R2 has **NO spending cap**. Turning it on asks for a payment method (card, PayPal or Google Pay), even if you only use the free part. Anything above the free tier is charged to that method every month.
> - The free tier (10 GB storage, 1M writes, 10M reads per month) belongs to the whole **Cloudflare account**, not to one bucket. Several buckets on the same account SHARE the same 10 GB.
> - Our own limits live in the database and the Edge Functions, **not** in Cloudflare: 8 GiB per storage, 8 GiB per Cloudflare account (all storages with the same `account_ref` together), 1 GiB per file. Files put into the bucket from outside the app are not counted until the purge job finds them.
> - If you use a prepaid / virtual card, put only a small balance on it: a charge above the free tier is then refused instead of paid.
> - R2 prices and rules change. Check https://www.cloudflare.com/products/r2/ before you start.

## 0. Before you start
Do these in order, nothing else is needed from the apps (they know no key, endpoint or bucket):
1. Supabase project with `001_accounts.sql` done (see the main README), and `supabase` CLI installed and logged in (`supabase login`, `supabase link --project-ref <ref>`).
2. Run the SQL tests on a LOCAL Postgres 16 first: `test_001.sql`, `test_003.sql` (stops at the first FAIL), `bash test_003_race.sh` (8 teachers ask for the last 3 GiB at once: exactly 3 must win). Every line must say PASS.
3. Supabase -> SQL Editor: run `003_storages.sql`.

## 1. Cloudflare R2 (account, bucket, keys)
1. Create the account at https://dash.cloudflare.com/sign-up and verify the email.
2. Dashboard -> Storage & databases -> R2 Object Storage -> activate R2 (payment method here). **Before you press the button, the amount due now must be zero** (see "Order summary").
3. Create a bucket (any name, for example `nexora-videos-1`). Keep it **PRIVATE**: do not turn on "Public access" and do not add a custom domain. All access is through links that expire (upload 1 hour, watching 3 hours).
4. Note the **Account ID** (R2 overview page). The endpoint is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
5. R2 -> Manage API tokens -> Create API token: permission **Object Read & Write**, applied to **this one bucket only**. Copy the **Access Key ID** and **Secret Access Key** (shown ONCE). The apps never see them.
6. No CORS rule is needed (the apps upload natively, not from a browser).

## 2. Secrets (Supabase -> Edge Functions -> Secrets, or the CLI)
The secret name is the **prefix** you will write in `storages.secret_name` (for example `R2_A`):
```
supabase secrets set R2_A_ACCESS_KEY_ID=<access key id> R2_A_SECRET_ACCESS_KEY=<secret access key>
supabase secrets set PURGE_SECRET=<a long random text, at least 16 characters>
```
Keys live ONLY in these secrets: never in a table, never in the apps, never in git. (`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are set by Supabase itself.)

## 3. Deploy the four Functions (CLI, not the dashboard: the dashboard editor does not bundle the shared folder `functions/_shared`)
From the folder `server/supabase`:
```
supabase functions deploy upload-url
supabase functions deploy upload-complete
supabase functions deploy play-url
supabase functions deploy purge-deleted --no-verify-jwt
```
`purge-deleted` is called by the schedule, not by a user, so JWT check is OFF and it protects itself with `PURGE_SECRET`. The other three keep JWT ON.

## 4. Add the first storage (Supabase -> SQL Editor)
```sql
insert into public.storages (name, endpoint, bucket, account_ref, secret_name, sort_order)
values ('R2 - 1', 'https://<ACCOUNT_ID>.r2.cloudflarestorage.com', 'nexora-videos-1', '<ACCOUNT_ID>', 'R2_A', 1);
```
`limit_bytes` defaults to 8 GiB and can never be set higher (the table refuses it). The admin edits only name, limit, on/off and order from the apps (Account tab -> Storage).

## 5. Schedule the purge (every 15 minutes)
Supabase -> Database -> Extensions: enable `pg_cron` and `pg_net`. Then in the SQL Editor:
```sql
select cron.schedule('purge-deleted', '*/15 * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/purge-deleted',
    headers := jsonb_build_object('x-purge-secret', '<PURGE_SECRET>'),
    body := '{}'::jsonb);
$$);
```
The secret is then stored inside the cron job (only the database owner sees it). To check it works: `select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;` and call the function once by hand with the same header: the answer is only counts (`expired, deleted, failed, orphans, reconciled, ...`), never keys or file names.

## 6. First test (small, before real lessons)
1. Teacher: upload a small video to a lesson. In the Storage screen `used` goes up by the file size.
2. Open the lesson as a student with access: it plays (link renews itself every time the lesson opens).
3. Delete that lesson / replace its video. After the next purge run (or a manual call) `used` goes back down. It goes down only after R2 confirmed the deletion.
4. Try a file over 1 GiB: "file too big". Switch the storage OFF from the admin screen: "storage off".
5. If a storage turns itself OFF, the purge job found that our counter and the real bucket size disagree, or it is nearly full: look at the bucket before switching it ON again.

## 7. Add a second storage
- **Another bucket on the SAME Cloudflare account**: same `account_ref`, and the new bucket/token. It does NOT give more free space: both storages share the same 8 GiB account limit. Use it only to organise.
- **A different Cloudflare account** (new 10 GB free, probably also asks for a payment method): new account id as `account_ref` and `endpoint`, its own bucket and token, and **a new secret prefix**:
```
supabase secrets set R2_B_ACCESS_KEY_ID=<...> R2_B_SECRET_ACCESS_KEY=<...>
```
```sql
insert into public.storages (name, endpoint, bucket, account_ref, secret_name, sort_order)
values ('R2 - 2', 'https://<ACCOUNT_ID_2>.r2.cloudflarestorage.com', 'nexora-videos-2', '<ACCOUNT_ID_2>', 'R2_B', 2);
```
Uploads go to the active storage with the lowest `sort_order` that has room for the file; when it is full, the next one is used automatically. When every storage is full the app says "all storages are full".

## 8. Not tested here
The Functions were written from the R2 / S3 documentation and checked against the SQL, never run against a real R2 bucket. Make the tests in section 6 before you trust it, and tell us the exact error text if one fails.
