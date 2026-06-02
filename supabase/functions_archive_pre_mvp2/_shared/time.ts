// Test-controllable clock for cron edge functions.
//
// Production behavior: `getNow()` returns `new Date()`. No surprises.
//
// Test/staging behavior: when env `ALLOW_CLOCK_OVERRIDE === "true"` AND the
// inbound request carries header `X-Test-Clock: <ISO8601>`, that timestamp
// is returned instead. This lets E2E tests advance the logical clock past
// fine grace periods + vote deadlines without sleeping for hours.
//
// Production safety contract:
//   - The env flag MUST NOT be set in production. There is no in-app
//     denylist — the deploy environment is the gate.
//   - When the override fires we emit a structured warn log so an operator
//     can see immediately if the flag was accidentally enabled in prod
//     (the log would appear in real production traffic).
//   - The header is silently ignored if the flag is off (no-op,
//     no log) — production requests pass through unaffected.

import { logStructured } from "./log.ts";

const FLAG_ENV = "ALLOW_CLOCK_OVERRIDE";
const HEADER = "X-Test-Clock";

export function clockOverrideEnabled(): boolean {
  return Deno.env.get(FLAG_ENV) === "true";
}

/**
 * Returns the current time the function should treat as "now".
 *
 * Pass the request whenever you have one — the header check is what makes
 * the clock controllable from tests. Calls without a request always return
 * `new Date()` (e.g. for sub-helpers that don't have access to the request
 * — only the entry-point handler should compute the override-aware now and
 * thread it down).
 */
export function getNow(req?: Request): Date {
  if (!req || !clockOverrideEnabled()) return new Date();

  const raw = req.headers.get(HEADER);
  if (!raw) return new Date();

  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) {
    logStructured({
      level: "warn",
      code: "time.clock_override_invalid",
      message: `Ignoring ${HEADER} header: ${raw} is not a valid ISO 8601 date`,
      header_value: raw,
      timestamp: new Date().toISOString(),
    });
    return new Date();
  }

  logStructured({
    level: "warn",
    code: "time.clock_override_applied",
    message: `Using ${HEADER} override: ${parsed.toISOString()}`,
    override_iso: parsed.toISOString(),
    real_iso: new Date().toISOString(),
    timestamp: new Date().toISOString(),
  });
  return parsed;
}
