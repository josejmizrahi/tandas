# Sentry MVP — Implementation Plan

> **Roadmap reference:** `Plans/Roadmap.md` §3 Fase 0 item #4 (Observabilidad mínima).
> **Scope:** "Minimum viable" Sentry — crash capture iOS + error logging Edge Functions + PII scrubbing + one alert. NO custom breadcrumbs, NO performance monitoring, NO PostHog. Those come after first beta testers, informed by real usage.
>
> **Time budget:** 60–90 min focused work.

---

## Goal

Detect failures in production before users report them. The minimum slice that prevents "no me abre" by WhatsApp from being the only signal.

## Scope

**In:**
- iOS crash capture with symbolicated stack traces
- Edge Function unhandled error capture
- Release / version tracking (which build crashed)
- PII scrubbing (no emails, phones, names in events)
- Privacy Policy update to disclose Sentry as third-party processor
- One alert (error rate > 1% in 5-min window → email)

**Out (future iterations):**
- Custom breadcrumbs in critical flows (rule engine firings, vote resolutions)
- Performance / transaction monitoring
- PostHog product analytics
- Custom dashboards beyond the default
- Alert rules tuned to specific user flows

The default capture is "good enough" until real testers generate real errors. Then tune.

---

## Prerequisites

- Sentry account (free tier supports 5k errors/month — sufficient for V1).
- Access to App Store Connect (for dSYM upload via Xcode automation).
- Access to Supabase project (for Edge Function deploy).

---

## Tasks

### 1. Account + project setup (10 min)

- [ ] Create account at `sentry.io` if not already.
- [ ] Create organization "ruul" (or reuse existing).
- [ ] Create two projects:
  - `ruul-ios` — platform: Apple → iOS
  - `ruul-edge` — platform: Node.js (use this even though it's Deno; Sentry's Deno-specific support is via `@sentry/deno` but Node SDK works fine via npm-compat in Deno)
- [ ] Copy DSN for each. Save as env vars later.
- [ ] In Sentry settings → Security & Privacy → enable "Scrub Data" by default + "Scrub IP Addresses".

### 2. iOS integration (20 min)

- [ ] Add Swift Package: `https://github.com/getsentry/sentry-cocoa` (latest 8.x).
- [ ] In `ios/Tandas/TandasApp.swift`, add to `init()`:

```swift
import Sentry

@main
struct TandasApp: App {
    init() {
        SentrySDK.start { options in
            options.dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String ?? ""
            options.releaseName = "ruul-ios@\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.0.0")+\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "0")"
            options.environment = #if DEBUG
                "development"
                #else
                "production"
                #endif
            options.tracesSampleRate = 0.0  // No performance monitoring in MVP
            options.attachScreenshot = false  // Privacy: no screenshots
            options.attachViewHierarchy = false  // Privacy: no view hierarchy
            options.beforeSend = { event in
                // Scrub user-identifying fields. Keep group_id and rule_id
                // for debugging; drop email/phone.
                event.user?.email = nil
                event.user?.username = nil
                event.user?.ipAddress = nil
                return event
            }
        }
        // Existing init code below…
    }
    // …
}
```

- [ ] Add `SENTRY_DSN` to `Tandas.xcconfig` (the iOS DSN from step 1):

```
SENTRY_DSN = https://abc123@o12345.ingest.sentry.io/67890
```

- [ ] In `Info.plist`, add: `<key>SENTRY_DSN</key><string>$(SENTRY_DSN)</string>`.

- [ ] Set up dSYM upload. Add a Run Script Build Phase to the Tandas target:

```sh
SENTRY_AUTH_TOKEN="$(cat $SRCROOT/.sentry-auth)" \
  /usr/local/bin/sentry-cli upload-dif \
  --org ruul --project ruul-ios "$DWARF_DSYM_FOLDER_PATH"
```

(Save the auth token in `.sentry-auth` at repo root, gitignore it. Generate via Sentry → Account → API → Auth Tokens with `project:write` scope.)

- [ ] Add `.sentry-auth` to `.gitignore`.

### 3. Edge Functions integration (15 min)

- [ ] In each edge function under `supabase/functions/`, add at the top:

```ts
import * as Sentry from "https://deno.land/x/sentry@8.40.0/mod.ts";

Sentry.init({
  dsn: Deno.env.get("SENTRY_DSN_EDGE") ?? "",
  environment: Deno.env.get("SUPABASE_ENV") ?? "production",
  release: Deno.env.get("DEPLOY_VERSION") ?? "unknown",
  tracesSampleRate: 0,
  beforeSend: (event) => {
    if (event.user) {
      delete event.user.email;
      delete event.user.username;
      delete event.user.ip_address;
    }
    return event;
  },
});
```

- [ ] Wrap each `Deno.serve` handler:

```ts
Deno.serve(async (req) => {
  try {
    return await handleRequest(req);
  } catch (e) {
    Sentry.captureException(e);
    return new Response(JSON.stringify({ error: "internal" }), { status: 500 });
  }
});
```

- [ ] Add `SENTRY_DSN_EDGE` to Supabase project secrets via dashboard (Project Settings → Edge Functions → Secrets) or:

```sh
supabase secrets set SENTRY_DSN_EDGE=https://xyz789@o12345.ingest.sentry.io/54321
```

- [ ] Redeploy edge functions:

```sh
supabase functions deploy --project-ref fpfvlrwcskhgsjuhrjpz
```

### 4. PII scrubbing — verify config (5 min)

- [ ] In Sentry → ruul-ios project → Settings → Security & Privacy:
  - "Prevent Storing of IP Addresses" ✓
  - "Data Scrubber" ✓
  - "Sensitive Fields": add `email`, `phone`, `phone_number`, `display_name`, `name`
- [ ] Repeat for ruul-edge project.

### 5. Privacy Policy update (5 min)

The current Privacy Policy lists Supabase + Apple. Add Sentry as third-party processor.

- [ ] In `legal/privacy-policy.md` (and the HTML mirror), Section 5 (Con quién compartimos tu información), add a new paragraph after the Apple paragraph:

> **Sentry (Functional Software, Inc.)** — para detectar fallas técnicas, usamos Sentry, que recibe trazas de errores y metadata del dispositivo (versión iOS, modelo, versión de la app). Configurado para no procesar información personal identificable: emails, teléfonos, ni nombres no se transmiten. Su política de privacidad está en `sentry.io/privacy`.

- [ ] Bump "Última actualización" to today's date.
- [ ] Re-deploy hosting (Vercel auto-redeploys on push if connected; otherwise re-upload).

### 6. Verification (10 min)

iOS:
- [ ] Build for simulator. In `ContentView` or somewhere reachable, temporarily add a debug button:
  ```swift
  Button("Test crash") { fatalError("Sentry test crash") }
  ```
- [ ] Run app, tap button. App crashes.
- [ ] Reopen app. Crash should upload on next launch.
- [ ] Verify in Sentry dashboard within ~30s.
- [ ] Stack trace should be symbolicated (function names visible, not hex addresses).
- [ ] Remove the test button before commit.

Edge Functions:
- [ ] Trigger a test error in any function. E.g., temporarily add `throw new Error("Sentry test")` in `process-system-events/index.ts`.
- [ ] Wait for next cron tick or invoke manually.
- [ ] Verify error appears in `ruul-edge` Sentry project within ~30s.
- [ ] Remove the test throw.

PII verification:
- [ ] In a test event, verify `user.email`, `user.ip_address` are missing.
- [ ] Verify event payload doesn't contain phone numbers (manually inspect).

### 7. One alert (5 min)

- [ ] In `ruul-ios` Sentry project → Alerts → Create Alert.
- [ ] Type: "Issue alert" → "Number of errors in an issue is more than X in Y time".
- [ ] Threshold: 5 errors in 5 minutes → trigger.
- [ ] Action: send to your email (`jose.mizrahi@quimibond.com`).
- [ ] Repeat for `ruul-edge`.

These are intentionally loose alerts. Tune after seeing real noise.

---

## Definition of Done

- [ ] iOS crashes appear in Sentry with symbolicated stack traces.
- [ ] Edge Function errors appear in Sentry.
- [ ] No PII in Sentry events (verified by manual inspection of one event).
- [ ] Privacy Policy mentions Sentry as third-party processor.
- [ ] Two alerts configured (one per project).
- [ ] DSN values in env, not hardcoded; auth token gitignored.
- [ ] Roadmap §3 Fase 0 item #4 — first checkbox marked done (Sentry portion; PostHog deferred).

## Commit structure (suggested)

Six commits, one per task:

```
chore(observability): Sentry account + project setup (no code change)
feat(ios): Sentry SDK init + DSN config + dSYM upload phase
feat(edge): Sentry init + Deno.serve error capture wrapper
chore(privacy): scrubbing config for Sentry projects
docs(legal): Privacy Policy v1.1 — disclose Sentry processor
chore(observability): two error-rate alerts configured
```

The final task ("verification + remove test code") happens before the iOS commit lands; not a separate commit.

---

## Rollback

If Sentry causes any issue (rare — SDK is stable):

- iOS: comment out the `SentrySDK.start { ... }` block. Build + push. SDK becomes inert; no further events captured.
- Edge: remove `Sentry.init` call from each function. Re-deploy.
- Sentry projects can be deleted from the Sentry dashboard with no data loss elsewhere.

No DB migrations involved; rollback is purely client/server config.

---

## Follow-ups (not V1)

- **PostHog product analytics** — funnel tracking from onboarding step 1 to first event closed. Wire after first 10 testers generate real onboarding data.
- **Custom breadcrumbs** for the rule engine: capture rule.id + trigger.eventType in the Sentry breadcrumb stream so when a rule engine error occurs, you see what rule fired and what it was processing.
- **Performance monitoring** in iOS for top-3 slowest views (HomeView, EventDetail, EditRulesView). Tune `tracesSampleRate` upward to 0.1 once volume is real.
- **Slack integration** instead of email alerts (when there's a team / channel to notify).
- **Source maps for edge functions** if Deno bundles obscure stack traces.
- **PII scrubbing tests** — automated verification that no scrubbed field appears in test events.
