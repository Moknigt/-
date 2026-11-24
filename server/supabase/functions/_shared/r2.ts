// Shared helpers for the 4 storage functions (upload-url, upload-complete, play-url, purge-deleted).
// Cloudflare R2 speaks the S3 protocol: region "auto", service "s3", path-style URLs  https://<account>.r2.cloudflarestorage.com/<bucket>/<key>
// No library: AWS Signature V4 written with WebCrypto, because presigning a PUT with a SIGNED Content-Length (the size we reserved) is what
// makes R2 refuse any other size, and the common libraries do not sign that header.
// R2 keys come ONLY from Edge Function secrets named <secret_name>_ACCESS_KEY_ID and <secret_name>_SECRET_ACCESS_KEY. Nothing here logs a URL, key or secret.

// ---- THE LIMITS: the same numbers as storage_cap_bytes() / max_file_bytes() in 003_storages.sql. Never raise them. ----
export const MAX_FILE_BYTES = 1073741824;      // 1 GiB per file
export const STORAGE_CAP_BYTES = 8589934592;   // 8 GiB per storage / per Cloudflare account
export const UPLOAD_TTL_SECONDS = 3600;        // presigned PUT lives at most 1 hour (reservations live 2 hours)
export const PLAY_TTL_SECONDS = 10800;         // presigned GET for watching: 3 hours, renewed by play-url every time the lesson is opened

export type Store = { endpoint: string; bucket: string; secret_name: string };
export type Creds = { id: string; secret: string };

export function credsFor(secretName: string): Creds | null {
  const id = Deno.env.get(`${secretName}_ACCESS_KEY_ID`);
  const secret = Deno.env.get(`${secretName}_SECRET_ACCESS_KEY`);
  return id && secret ? { id, secret } : null;
}

const enc = new TextEncoder();
const hex = (b: ArrayBuffer | Uint8Array) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
async function sha256Hex(s: string) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
async function hmac(key: ArrayBuffer | Uint8Array | string, msg: string): Promise<ArrayBuffer> {
  const raw = typeof key === "string" ? enc.encode(key) : key;
  const k = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(msg));
}
const rfc3986 = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
const encKey = (key: string) => key.split("/").map(rfc3986).join("/");

async function signingKey(secret: string, day: string) {
  const kDate = await hmac("AWS4" + secret, day);
  const kRegion = await hmac(kDate, "auto");
  const kService = await hmac(kRegion, "s3");
  return hmac(kService, "aws4_request");
}
function stamp(d = new Date()) {
  const iso = d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20260101T000000Z
  return { amz: iso, day: iso.slice(0, 8) };
}
function objectUrl(st: Store, key?: string) {
  const base = st.endpoint.replace(/\/+$/, "");
  return { base, host: new URL(base).host, path: `/${rfc3986(st.bucket)}${key ? "/" + encKey(key) : ""}` };
}
const canonQuery = (q: Record<string, string>) => Object.keys(q).sort().map((k) => `${rfc3986(k)}=${rfc3986(q[k])}`).join("&");

// ---- presigned URL (query string signing). For PUT, contentLength is SIGNED: the client must send exactly that many bytes. ----
export async function presign(st: Store, c: Creds, method: "PUT" | "GET", key: string, expires: number, opts: { contentLength?: number; now?: Date } = {}): Promise<string> {
  const { base, host, path } = objectUrl(st, key);
  const { amz, day } = stamp(opts.now);
  const scope = `${day}/auto/s3/aws4_request`;
  const signed = method === "PUT" ? "content-length;host" : "host";
  const headers = method === "PUT" ? `content-length:${opts.contentLength}\nhost:${host}\n` : `host:${host}\n`;
  const q: Record<string, string> = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": `${c.id}/${scope}`, "X-Amz-Date": amz,
    "X-Amz-Expires": String(Math.min(Math.max(Math.floor(expires), 1), 604800)), "X-Amz-SignedHeaders": signed,
  };
  const cq = canonQuery(q);
  const canonical = [method, path, cq, headers, signed, "UNSIGNED-PAYLOAD"].join("\n");
  const toSign = ["AWS4-HMAC-SHA256", amz, scope, await sha256Hex(canonical)].join("\n");
  const sig = hex(await hmac(await signingKey(c.secret, day), toSign));
  return `${base}${path}?${cq}&X-Amz-Signature=${sig}`;
}

// ---- server-side request signed with the Authorization header (HEAD / DELETE / list). Body is always empty. ----
async function signedFetch(st: Store, c: Creds, method: "HEAD" | "DELETE" | "GET", key: string | null, query: Record<string, string> = {}): Promise<Response> {
  const { base, host, path } = objectUrl(st, key ?? undefined);
  const { amz, day } = stamp();
  const scope = `${day}/auto/s3/aws4_request`;
  const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";   // sha256 of ""
  const signed = "host;x-amz-content-sha256;x-amz-date";
  const headers = `host:${host}\nx-amz-content-sha256:${empty}\nx-amz-date:${amz}\n`;
  const cq = canonQuery(query);
  const canonical = [method, path, cq, headers, signed, empty].join("\n");
  const toSign = ["AWS4-HMAC-SHA256", amz, scope, await sha256Hex(canonical)].join("\n");
  const sig = hex(await hmac(await signingKey(c.secret, day), toSign));
  return fetch(`${base}${path}${cq ? "?" + cq : ""}`, {
    method,
    headers: { "x-amz-date": amz, "x-amz-content-sha256": empty, Authorization: `AWS4-HMAC-SHA256 Credential=${c.id}/${scope}, SignedHeaders=${signed}, Signature=${sig}` },
  });
}

// size in bytes, or null when the object does not exist (404). Any other answer THROWS (never guess a size).
export async function headSize(st: Store, c: Creds, key: string): Promise<number | null> {
  const r = await signedFetch(st, c, "HEAD", key);
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`head_${r.status}`);
  const n = Number(r.headers.get("content-length"));
  if (!Number.isFinite(n) || n < 0) throw new Error("head_no_length");
  return n;
}

// true = the object is gone (deleted now or it was already gone). 404 counts as success. Anything else THROWS.
export async function deleteObject(st: Store, c: Creds, key: string): Promise<true> {
  const r = await signedFetch(st, c, "DELETE", key);
  if (r.status === 404 || r.ok) return true;
  throw new Error(`delete_${r.status}`);
}

// every object of the bucket: [{key, size, modified}] (ListObjectsV2, paged). Used by purge-deleted to know the REAL total.
export async function listAll(st: Store, c: Creds, maxPages = 200): Promise<{ key: string; size: number; modified: number }[]> {
  const out: { key: string; size: number; modified: number }[] = [];
  let token = "";
  for (let page = 0; page < maxPages; page++) {
    const q: Record<string, string> = { "list-type": "2", "max-keys": "1000" };
    if (token) q["continuation-token"] = token;
    const r = await signedFetch(st, c, "GET", null, q);
    if (!r.ok) throw new Error(`list_${r.status}`);
    const xml = await r.text();
    for (const m of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
      const key = /<Key>([\s\S]*?)<\/Key>/.exec(m[1])?.[1];
      const size = Number(/<Size>(\d+)<\/Size>/.exec(m[1])?.[1]);
      const mod = Date.parse(/<LastModified>([\s\S]*?)<\/LastModified>/.exec(m[1])?.[1] ?? "");
      if (key == null || !Number.isFinite(size)) throw new Error("list_parse");
      out.push({
        key: key.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'"),
        size, modified: Number.isFinite(mod) ? mod : 0,
      });
    }
    if (!/<IsTruncated>true<\/IsTruncated>/.test(xml)) return out;
    token = /<NextContinuationToken>([\s\S]*?)<\/NextContinuationToken>/.exec(xml)?.[1] ?? "";
    if (!token) throw new Error("list_no_token");
  }
  throw new Error("list_too_long");   // never report a partial total as the real one
}

// ---- small shared bits ----
export const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Content-Type": "application/json" };
export const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: cors });
export const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
// the "reason" values of 003_storages.sql, mapped to HTTP status; the apps translate the reason to Arabic / English
export const REASON_STATUS: Record<string, number> = {
  bad_size: 400, too_large: 413, not_allowed: 403, not_your_lesson: 403, too_many_open: 429, full: 409,
  missing: 404, no_object: 409, size_mismatch: 409, expired: 410, lesson_gone: 410, rejected: 409,
};
