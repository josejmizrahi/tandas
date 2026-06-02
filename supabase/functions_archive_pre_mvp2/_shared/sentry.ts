// Sentry MVP — Edge Function instrumentation helper.
//
// Single point of init + a `withSentry(handler)` wrapper so each edge
// function adds two lines (one import + one wrap) instead of copy-pasting
// the SDK config. Privacy: PII scrubbed in beforeSend; tracesSampleRate=0
// (no performance monitoring in MVP).
//
// DSN is read from `SENTRY_DSN_EDGE` Supabase secret. If unset, the SDK
// becomes inert (events are not transmitted) — safe for local dev.

import * as Sentry from "npm:@sentry/node@^8";

let initialized = false;

function initOnce() {
  if (initialized) return;
  initialized = true;

  const dsn = Deno.env.get("SENTRY_DSN_EDGE") ?? "";
  if (!dsn) return;

  Sentry.init({
    dsn,
    environment: Deno.env.get("SENTRY_ENV") ?? "production",
    release: Deno.env.get("SENTRY_RELEASE") ?? "ruul-edge@unknown",
    tracesSampleRate: 0,
    sendDefaultPii: false,
    beforeSend(event) {
      if (event.user) {
        delete event.user.email;
        delete event.user.username;
        delete event.user.ip_address;
      }
      return event;
    },
  });
}

initOnce();

export interface SentryContext {
  /** Edge function name, used as a tag on captured exceptions. */
  functionName: string;
}

/**
 * Wraps a request handler so any thrown error is reported to Sentry
 * before being returned as a 500 to the client. Idempotent on repeated
 * calls (init runs once per worker).
 */
export function withSentry<T extends (req: Request) => Response | Promise<Response>>(
  handler: T,
  ctx: SentryContext,
): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      Sentry.withScope((scope) => {
        scope.setTag("edge_function", ctx.functionName);
        scope.setExtra("url", req.url);
        scope.setExtra("method", req.method);
        Sentry.captureException(e);
      });
      // Best-effort flush so the event reaches Sentry before the worker
      // is recycled. Keep timeout tight; we don't want to slow the
      // 500 response materially.
      try {
        await Sentry.flush(2000);
      } catch (_) {
        // ignore flush errors
      }
      return new Response(
        JSON.stringify({ error: "internal" }),
        { status: 500, headers: { "content-type": "application/json" } },
      );
    }
  };
}

/**
 * Direct capture for non-handler contexts (e.g., cron loops where the
 * "request" abstraction doesn't apply). Still respects the global init.
 */
export function captureEdgeException(error: unknown, ctx: SentryContext, extras?: Record<string, unknown>) {
  Sentry.withScope((scope) => {
    scope.setTag("edge_function", ctx.functionName);
    if (extras) {
      for (const [k, v] of Object.entries(extras)) {
        scope.setExtra(k, v);
      }
    }
    Sentry.captureException(error);
  });
}
