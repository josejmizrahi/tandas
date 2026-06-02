// HTTP helper for invoking cron edge functions with optional clock override.
//
// Why a helper: the supabase-js `functions.invoke` method doesn't pass
// arbitrary headers, and the X-Test-Clock header is the entire reason
// we have a controlled clock. So we use raw fetch with the service-role
// JWT for auth.

import { loadEnv } from "./env.ts";

const env = loadEnv();

export interface InvokeOpts {
  /** ISO 8601 timestamp the cron should treat as "now". */
  clockOverride?: Date | string;
  /** JSON body. Most crons take none. */
  body?: unknown;
  /** HTTP method. Default POST (matches `serve` handler convention). */
  method?: "GET" | "POST";
}

export interface InvokeResult {
  status: number;
  ok: boolean;
  body: unknown;
}

export async function invokeCron(name: string, opts: InvokeOpts = {}): Promise<InvokeResult> {
  const url = `${env.functionsUrl}/${name}`;
  const headers: Record<string, string> = {
    "Authorization": `Bearer ${env.serviceRoleKey}`,
    "Content-Type": "application/json",
  };
  if (opts.clockOverride) {
    const iso = typeof opts.clockOverride === "string"
      ? opts.clockOverride
      : opts.clockOverride.toISOString();
    headers["X-Test-Clock"] = iso;
  }

  const res = await fetch(url, {
    method: opts.method ?? "POST",
    headers,
    body: opts.body ? JSON.stringify(opts.body) : "{}",
  });

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    body = await res.text();
  }

  return { status: res.status, ok: res.ok, body };
}
