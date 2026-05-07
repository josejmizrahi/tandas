// dispatch-notifications: cron that drains notifications_outbox to APNs.
//
// Runs every 1 minute. Reads outbox rows where `dispatched_at IS NULL`,
// looks up notification_tokens for each recipient_member_id, signs an
// APNs JWT (ES256 with the .p8 in APNS_AUTH_KEY), POSTs to APNs HTTP/2,
// and marks each row sent / failed / skipped.
//
// Atomic claim: the SELECT-then-UPDATE pattern relies on Postgres
// row-level locks. Concurrent invocations of this function won't double-
// claim because the WHERE `dispatched_at IS NULL` predicate re-evaluates
// after each row's UPDATE commits.
//
// Idempotency: a row claimed but not yet finalized has `dispatched_at`
// set but `dispatch_status='pending'`. If the function dies before
// finalizing, the row is "orphaned" — claimed but never marked. A
// future janitor can recover (reset dispatch_status='pending' AND
// dispatched_at=NULL where age > 5min). V1 doesn't ship the janitor;
// stuck rows are observable via SQL.
//
// JWT cache: APNs allows tokens valid 60min. We cache for 50min and
// re-mint on demand. Cache is module-level (per-function-instance, but
// short-lived containers are fine — re-minting is ~5ms).
//
// Required env:
//   APNS_AUTH_KEY      — full PEM contents of the .p8 (with BEGIN/END lines)
//   APNS_KEY_ID        — 10-char key id from Apple Developer portal
//   APNS_TEAM_ID       — 10-char team id
//   APNS_BUNDLE_ID     — app bundle identifier (apns-topic)
//   APNS_USE_SANDBOX   — "true" (default) for dev/TestFlight, "false" for prod
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — DB access

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APNS_AUTH_KEY = Deno.env.get("APNS_AUTH_KEY") ?? "";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "";
const APNS_USE_SANDBOX = (Deno.env.get("APNS_USE_SANDBOX") ?? "true").toLowerCase() === "true";

const APNS_HOST = APNS_USE_SANDBOX
  ? "https://api.sandbox.push.apple.com"
  : "https://api.push.apple.com";

const BATCH_LIMIT = parseInt(Deno.env.get("DISPATCH_BATCH_LIMIT") ?? "100");

interface OutboxRow {
  id: string;
  group_id: string;
  recipient_member_id: string;
  notification_type: string;
  payload: Record<string, unknown>;
  deep_link: string | null;
}

interface DispatchSummary {
  claimed: number;
  sent: number;
  failed: number;
  skipped: number;
  errors: Array<{ outbox_id: string; reason: string }>;
}

serve(withSentry(async (_req) => {
  if (!APNS_AUTH_KEY || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_BUNDLE_ID) {
    return jsonError(500, "missing APNs env vars");
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Atomic claim via SECURITY DEFINER RPC. The function uses
  // FOR UPDATE SKIP LOCKED so concurrent invocations don't double-claim.
  // Going through RPC instead of `.from(...)` table reads bypasses
  // PostgREST's schema cache (which can lag behind DDL changes).
  const { data: claimed, error: claimErr } = await supabase.rpc(
    "claim_pending_outbox",
    { p_limit: BATCH_LIMIT },
  );

  if (claimErr) return jsonError(500, `claim failed: ${claimErr.message}`);

  const rows = (claimed ?? []) as OutboxRow[];
  const summary: DispatchSummary = {
    claimed: rows.length,
    sent: 0,
    failed: 0,
    skipped: 0,
    errors: [],
  };

  if (rows.length === 0) return ok(summary);

  // Resolve recipient_member_id → user_id → tokens (per-row map). One
  // recipient may have multiple tokens (multiple devices). We send to
  // each.
  const memberIds = [...new Set(rows.map((r) => r.recipient_member_id))];
  const { data: members } = await supabase
    .from("group_members")
    .select("id, user_id")
    .in("id", memberIds);

  const userIdByMember = new Map<string, string>(
    ((members ?? []) as Array<{ id: string; user_id: string }>).map((m) => [m.id, m.user_id]),
  );

  const userIds = [...new Set([...userIdByMember.values()])];
  const { data: tokens } = await supabase
    .from("notification_tokens")
    .select("user_id, token, platform")
    .in("user_id", userIds)
    .eq("platform", "ios");

  const tokensByUser = new Map<string, string[]>();
  for (const t of (tokens ?? []) as Array<{ user_id: string; token: string; platform: string }>) {
    const list = tokensByUser.get(t.user_id) ?? [];
    list.push(t.token);
    tokensByUser.set(t.user_id, list);
  }

  // Dispatch each row.
  const jwt = await getApnsJwt();
  for (const row of rows) {
    const userId = userIdByMember.get(row.recipient_member_id);
    const userTokens = userId ? (tokensByUser.get(userId) ?? []) : [];

    if (userTokens.length === 0) {
      await supabase.rpc("mark_outbox_skipped", {
        p_outbox_id: row.id,
        p_reason: "no token registered",
      });
      summary.skipped += 1;
      continue;
    }

    const apnsBody = buildApnsBody(row);
    let lastErr: string | null = null;
    let anySuccess = false;

    for (const token of userTokens) {
      const result = await sendApns(token, apnsBody, jwt);
      if (result.ok) {
        anySuccess = true;
      } else {
        lastErr = result.error;
        // 410 Gone or BadDeviceToken: token is invalid, remove it so we
        // stop wasting attempts on it.
        if (result.status === 410 || /BadDeviceToken/i.test(result.error)) {
          await supabase.from("notification_tokens").delete().eq("token", token);
        }
      }
    }

    if (anySuccess) {
      await supabase.rpc("mark_outbox_sent", { p_outbox_id: row.id });
      summary.sent += 1;
    } else {
      const reason = lastErr ?? "unknown apns error";
      await supabase.rpc("mark_outbox_failed", {
        p_outbox_id: row.id,
        p_error: reason,
      });
      summary.failed += 1;
      summary.errors.push({ outbox_id: row.id, reason });
    }
  }

  return ok(summary);
}, { functionName: "dispatch-notifications" }));

// ============================================================================
// APNs body composition
// ============================================================================

function buildApnsBody(row: OutboxRow): Record<string, unknown> {
  const payload = row.payload ?? {};
  const title = (payload.title as string | undefined) ?? "ruul";
  const body = (payload.body as string | undefined) ?? "";

  // Standard APNs alert envelope plus our custom keys for deep linking.
  // The iOS client's UNUserNotificationCenterDelegate reads userInfo
  // (everything alongside `aps`) — we put deep_link there for routing.
  return {
    aps: {
      alert: { title, body },
      sound: "default",
    },
    deep_link: row.deep_link ?? null,
    notification_type: row.notification_type,
    outbox_id: row.id,
  };
}

// ============================================================================
// APNs HTTP/2 send (Deno's fetch uses HTTP/2 transparently when available)
// ============================================================================

async function sendApns(
  token: string,
  body: Record<string, unknown>,
  jwt: string,
): Promise<{ ok: true; status: 200; apnsId: string | null } | { ok: false; status: number; error: string }> {
  const url = `${APNS_HOST}/3/device/${token}`;
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    return { ok: false, status: 0, error: `fetch threw: ${(e as Error).message}` };
  }

  // Log diagnostic info on every send — apns-id is the trace id Apple
  // uses in their Push Notification Console; topic confirms what bundle
  // we targeted; first chars of token confirm we sent to the right device.
  const apnsId = res.headers.get("apns-id");
  console.log(JSON.stringify({
    code: "apns.send",
    status: res.status,
    apns_id: apnsId,
    topic: APNS_BUNDLE_ID,
    host: APNS_HOST,
    token_prefix: token.slice(0, 12),
  }));

  if (res.status === 200) return { ok: true, status: 200, apnsId };

  let errText = "";
  try {
    errText = await res.text();
  } catch { /* ignore */ }
  return { ok: false, status: res.status, error: `apns ${res.status}: ${errText.slice(0, 200)}` };
}

// ============================================================================
// APNs JWT (ES256 with kid header) — cached for ~50 minutes
// ============================================================================

let cachedJwt: { token: string; mintedAt: number } | null = null;
const JWT_CACHE_MS = 50 * 60 * 1000;

async function getApnsJwt(): Promise<string> {
  const now = Date.now();
  if (cachedJwt && now - cachedJwt.mintedAt < JWT_CACHE_MS) {
    return cachedJwt.token;
  }

  const header = { alg: "ES256", kid: APNS_KEY_ID, typ: "JWT" };
  const claims = { iss: APNS_TEAM_ID, iat: Math.floor(now / 1000) };

  const headerB64 = b64url(JSON.stringify(header));
  const claimsB64 = b64url(JSON.stringify(claims));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await importApnsPrivateKey(APNS_AUTH_KEY);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  const sigB64 = b64urlBytes(new Uint8Array(signature));
  const token = `${signingInput}.${sigB64}`;

  cachedJwt = { token, mintedAt: now };
  return token;
}

async function importApnsPrivateKey(pem: string): Promise<CryptoKey> {
  // Strip PEM headers + whitespace, base64-decode, import as PKCS8.
  const b64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function b64url(s: string): string {
  return b64urlBytes(new TextEncoder().encode(s));
}

function b64urlBytes(bytes: Uint8Array): string {
  let str = "";
  for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ============================================================================
// Helpers
// ============================================================================

function ok(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
