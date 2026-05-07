# OnboardingV1 — Follow-Up Items

Items deferred from the V1 implementation that need attention before V1
can ship to real users on TestFlight. None block local development or the
test suite; all are real-world infra setup or design decisions you need
to make.

---

## 1. Anonymous Supabase auth (BLOCKER for the "group lives at step 2" promise)

**Problem**: The founder flow creates the group at step 2 (GroupIdentityView)
**before** the user has verified their phone. `create_group_with_admin` RPC
requires `auth.uid() is not null`. A user who hasn't logged in can't call
this RPC.

**The spec wants**: "el grupo está vivo en Supabase tan pronto tiene nombre".

**Two paths to fix**:

### Path A — Enable anonymous sign-ins (recommended)
1. Go to Supabase Dashboard → Authentication → Providers → "Anonymous sign-ins"
   → toggle ON.
2. In `TandasApp.init`, call `client.auth.signInAnonymously()` if there's
   no session yet, before AuthGate routes anywhere. This gives every
   first-launch user an `auth.users` row immediately.
3. At step 5a (PhoneVerifyView OTP), upgrade the anonymous user to a
   phone-authenticated user. `LiveOTPService.verifyCode` already calls
   `setSession` after the edge function returns tokens; for an anonymous
   user this REPLACES their session with the phone-authenticated one.
   The auth.users.id changes — which means the `groups.created_by` and
   `group_members.user_id` references need to update too.
4. Edge function `verify-otp` needs to: (a) detect that the caller has an
   anonymous session, (b) link rather than create. Supabase exposes
   `auth.admin.updateUserById(id, { phone })` for this, but only after
   verifying the new credential. Workflow:
   - Client sends `{phone, code, channel, current_user_id}` to verify-otp.
   - Edge function validates code (as today).
   - If `current_user_id` is anonymous, call `updateUserById` to attach
     the phone — keeping the same UUID. groups + members rows stay valid.
   - Return new session tokens.

This requires updating verify-otp + the iOS OTPService protocol to pass
the current user id along.

### Path B — Phone-verify at step 1 (breaks the spec)
Move phone verification to BEFORE GroupIdentityView. User can't proceed
to "Crea tu grupo" until they're authenticated. Cleaner from a Supabase
auth POV but breaks "el grupo nace al ponerle nombre" promise + the
3-minute UX target.

### My recommendation
Path A. The 3-minute UX promise is core to the design. Pre-shipping V1
means coordinating with whoever owns the Supabase project to (a) enable
anonymous sign-ins, (b) deploy the updated verify-otp, (c) test the
upgrade-from-anon path end-to-end.

---

## 2. AASA file deployment to ruul.app

**Problem**: Universal Links require an AASA file at
`https://ruul.app/.well-known/apple-app-site-association`. Without it,
the entitlement `applinks:ruul.app` is dead — links will fall back to
the browser, not open the app.

**Status**: V1 ships with `applinks:ruul.app` in entitlements +
`Plans/Templates/apple-app-site-association.json` ready to deploy. Until
that file is live, share-link invites use a custom scheme
(`ruul://invite/<code>`) which only works if the app is already installed.

**Steps**:
1. Confirm `ruul.app` is registered + you have access to hosting.
2. Deploy the contents of `Plans/Templates/apple-app-site-association.json`
   to `https://ruul.app/.well-known/apple-app-site-association`.
3. Confirm with `curl https://ruul.app/.well-known/apple-app-site-association`
   that it returns the JSON with `Content-Type: application/json`.
4. After first deploy, Apple's CDN caches the file for ~48h. To force a
   refresh during dev, build the app, install fresh on simulator, and
   open Settings → Developer → Universal Links → ruul.app.

---

## 3. Wassenger configuration

**Problem**: V1 ships `send-otp` + `verify-otp` + `send-whatsapp-invite`
edge functions that depend on `WASSENGER_API_KEY` + `WASSENGER_DEVICE_ID`
secrets. Without these, the edge functions silently fall back to
SMS-only (which is fine but you lose the WhatsApp UX).

**Steps**:
1. Sign up at wassenger.com, register a WhatsApp device.
2. `supabase secrets set WASSENGER_API_KEY=... WASSENGER_DEVICE_ID=...`
3. Optional: `supabase secrets set WASSENGER_TIMEOUT_MS=5000`
4. Deploy: `supabase functions deploy send-otp verify-otp send-whatsapp-invite`

**Risk**: the WhatsApp branch in `verify-otp` mints a session via
`auth.admin.generateLink({type: "magiclink"})`. This may not work in all
Supabase plans / configurations. If it returns 503, the iOS client
should retry with channel=sms (per the contract). I instrumented the
fallback but did NOT test it end-to-end against a live Supabase. First
real-world test will validate.

---

## 4. Apple Wallet pass cert (V2)

V1 ships `StubWalletPassGenerator` that returns nil (no-op). The "Add to
Wallet" affordance never appears in `GroupTourOverlay`.

**Steps for V2**:
1. Generate Pass Type ID + cert in Apple Developer.
2. Add entitlement `com.apple.developer.pass-type-identifiers`.
3. Build edge function `generate-event-pass` that signs a `.pkpass`
   bundle (use `node-passkit-generator` style logic in Deno).
4. Replace `StubWalletPassGenerator` with `LiveWalletPassGenerator`
   that calls the edge function and returns the URL of the signed
   pass.

---

## 5. PostHog wiring (currently `LogAnalyticsService`)

V1 uses `LogAnalyticsService` which logs events to OSLog only. PostHog
SDK isn't wired.

**Steps**:
1. Add PostHog SwiftPM dependency: `https://github.com/PostHog/posthog-ios`
2. Implement `PostHogAnalyticsService: AnalyticsService` that maps
   `AnalyticsEvent.name + properties` to `PostHog.shared.capture(...)`
3. Configure API key via `Tandas.local.xcconfig` (NEVER commit the key).
4. In `TandasApp.init`, swap `LogAnalyticsService()` → `PostHogAnalyticsService()`.

---

## 6. Snapshot tests (V1.x)

The plan called for snapshot tests of every onboarding view × {default,
loading, filled, error} × {light, dark, HC}. V1 ships unit tests only —
snapshot tests deferred until you can run them on a Mac simulator (I
can't generate baseline images from Linux).

**Steps when you're ready**:
1. Open Xcode → record snapshots for each view by running the test
   target with `record: true` once.
2. Commit the `__Snapshots__/` folder.
3. Subsequent runs will diff against recorded baselines.

---

## 7. UI test rewrite

`HappyPathTests.swift` is currently disabled. The test was written
against Phase 1's LoginView/EmptyGroupsView/NewGroupWizard, which V1
deletes. Rewrite to drive the founder onboarding path:

```
welcome → identity (type "Test") → group (type "Test Group", pick cover) →
skip vocab → skip rules → skip invite → phone → mock-auto-verify → confirmation
```

Mock OTP service auto-verifies any code; mock groups repo accepts any
draft. UI test runs entirely against `TANDAS_USE_MOCKS=1`.

---

## 8. Avatar upload to Supabase Storage

V1 captures the avatar via PhotosPicker but stores it locally only —
never uploads to Supabase Storage. Both flows (founder + invited)
display the placeholder + capture the file but don't persist it
remotely. To complete V1.x:

1. Create a Supabase Storage bucket `avatars` with appropriate RLS.
2. Upload from `loadAvatar(from:)` immediately after capture, get URL.
3. Pass URL to `MemberRepository.upsertMyMembership(...)` after OTP.
4. Replace `RuulAvatar(name:)` placeholder with `RuulAvatar(name:imageURL:)`.

---

## 9. The "send invites via Wassenger" path is not wired in V1

`InviteMembersView` collects pending invites (phone numbers + names) but
the `coordinator.advanceFromInvite()` only calls
`inviteRepo.createInvite(...)` which inserts into the `invites` table —
it does NOT trigger the WhatsApp send. The `send-whatsapp-invite` edge
function exists, but the coordinator doesn't call it.

**To complete**: in `advanceFromInvite()`, after `createInvite` succeeds,
call the edge function. If WASSENGER not configured, fail silently
(invite row exists, recipient won't get the message, but they can be
re-invited later).

---

## 10. Coordinator handoff post-OTP

When the founder completes OTP at step 5b, `LiveOTPService.verifyCode`
installs the new session via `client.auth.setSession(...)`. AppState's
session stream fires, and... currently AuthGate evaluates `app.session
== nil` to decide onboarding vs main view. After OTP, session is no
longer nil, so AuthGate unmounts OnboardingRootView mid-flow.

**This breaks step 6 (Confirmation)**, which is part of the founder
flow but runs AFTER session is set.

**Fix**: the founder coordinator needs to override AuthGate's "show
main app once authenticated" behavior until the flow truly ends.
Simplest: AuthGate checks if there's an active OnboardingProgress in
SwiftData and keeps OnboardingRootView mounted as long as it exists.
The coordinator clears progress only when the user taps a destination
on ConfirmationView.

This is wired correctly in the coordinators (`finishOnboarding()` clears
progress) but AuthGate doesn't currently inspect SwiftData. Will require
refactoring `AuthGate` body to query OnboardingProgressManager before
deciding.

---

## Priority order

1. **Item 10 (auth handoff)** — blocks the happy path end-to-end.
2. **Item 1 (anonymous auth)** — blocks the "group lives at step 2" promise.
3. **Item 2 (AASA)** — blocks invite link sharing in V1 with non-installed users.
4. **Item 9 (Wassenger invite send)** — soft-blocks; flow works but recipients
   don't get WhatsApp messages.
5. **Item 3 (Wassenger setup)** — required for WhatsApp UX; SMS fallback
   works without it.
6. Items 4-8: polish, V2 work, deferred per plan.
