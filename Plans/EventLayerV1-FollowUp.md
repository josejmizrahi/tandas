# EventLayerV1 — Follow-Up Items

V1 ships features that are gated by infra you need to provision before
real-world use. None block local dev or CI; all are infra setup.

---

## 1. APNs cert + remote push

V1 ships local notifications fully wired (24h/2h/start reminders for
RSVPs=going). Remote push functions log only.

**Steps for V1.x**:
1. Apple Developer → Keys → APNs Auth Key (.p8). Note Key ID + Team ID.
2. Supabase Dashboard → Settings → Auth → APNs Configuration. Upload
   the .p8, fill Key ID + Team ID + bundle id (`com.josejmizrahi.ruul`).
3. Replace the stub at `supabase/functions/send-event-notification/
   index.ts` with a real fetch to APNs HTTP/2 (or use the
   supabase-js `auth.admin.notifications` helper if available).
4. Wire `application:didFinishLaunchingWithOptions:` to call
   `UIApplication.shared.registerForRemoteNotifications()` on launch
   when authorized — currently it's only called inside
   `NotificationService.requestAuthorization()` after the user grants
   permission.

---

## 2. Apple Wallet pass

V1 ships `StubWalletPassService` (`isAvailable=false`). The "Add to
Wallet" button never appears in `EventRSVPStateView`.

**Steps for V1.x**:
1. Apple Developer → Certificates → Pass Type ID + signing cert.
2. Add entitlement `com.apple.developer.pass-type-identifiers` with
   the Pass Type ID.
3. Supabase secrets:
   ```
   supabase secrets set RUUL_WALLET_PASS_TYPE_ID=...
   supabase secrets set RUUL_WALLET_CERT_PEM=$(cat cert.pem)
   supabase secrets set RUUL_WALLET_KEY_PEM=$(cat key.pem)
   ```
4. Replace the stub at `supabase/functions/generate-wallet-pass/
   index.ts` with a real `.pkpass` builder. Suggest passkit-generator
   port or native Deno HMAC + zip signing.
5. Replace `StubWalletPassService` with `LiveWalletPassService` that
   calls the edge function and presents the resulting `.pkpass` URL
   via `PKAddPassesViewController`.

---

## 3. RUUL_QR_SECRET provisioning

The QR signature uses an HMAC-SHA256 with a shared secret stored at
both:
- iOS client: `ios/Tandas.local.xcconfig` → `RUUL_QR_SECRET=...`
- Supabase secrets (when generate-wallet-pass real impl lands).

**Steps**:
1. Generate: `openssl rand -hex 32`
2. Copy `ios/Tandas.local.xcconfig.example` → `ios/Tandas.local.xcconfig`
   (gitignored) and paste the secret.
3. Add `RUUL_QR_SECRET` GitHub Actions secret so CI can build
   (workflow falls back to `test-qr-secret-for-ci-only` if missing —
   tests still pass with that placeholder).
4. When wiring the real Wallet edge function, run:
   `supabase secrets set RUUL_QR_SECRET=...` with the SAME value.

**V2 upgrade** (per Plans/EventLayerV1.md §13.6): move signature
validation to backend-only. Client posts the scanned QR payload to a
new edge function (`verify-checkin-qr`); function validates with the
secret and returns `{ event_id, member_id }` or 401. Removes the
need to ship the secret on the client.

---

## 4. Edge functions to deploy

V1 ships 4 edge functions in `supabase/functions/`:
- `auto-close-events` — cron `0 * * * *`. Real impl, ready.
- `auto-generate-events` — cron `0 */2 * * *`. Real impl, optional
  safety net (client-trigger is the primary path for recurrence).
- `send-event-notification` — STUB until APNs configured.
- `generate-wallet-pass` — STUB until cert configured.

```bash
supabase functions deploy auto-close-events
supabase functions deploy auto-generate-events
supabase functions deploy send-event-notification
supabase functions deploy generate-wallet-pass
```

Schedule via Supabase Dashboard → Edge Functions → Cron Jobs (or
the `supabase functions schedule` CLI).

---

## 5. Member lookup wiring

`MainTabView.eventDetailScreen(_:)` currently passes a placeholder
`memberLookup: { _ in (name: "Member", avatarURL: nil) }`. Real
implementation requires querying `group_members + profiles` via
`MemberRepository`. V1.x: extend MemberRepository with a
`func members(in:)` async actor method that returns
`[(userId: UUID, name: String, avatarURL: URL?)]`, cache the result
in a `MainTabView` @State, and pass a closure that looks up by id.
Falls back to "Miembro" for unknown ids.

Same for `CheckInScannerCoordinator.memberLookup`.

---

## 6. Avatar upload to Supabase Storage

Onboarding V1 captured avatars locally only. Same pattern continues
for event creation (cover image custom upload via PhotosPicker is
captured but not uploaded — `coverImageURL` stays nil).

To complete V1.x:
1. Create Supabase Storage bucket `event-covers` with appropriate RLS
   (admin write, group member read).
2. In `CreateEventView`, after PhotosPicker selection, upload the
   image data via `client.storage.from("event-covers").upload(...)`,
   set `draft.coverImageURL` to the public URL.
3. Same path for `avatars` bucket if you want member avatar uploads
   from onboarding to actually persist.

---

## 7. EditEventView

V1 plan listed `EditEventView` but I deferred its implementation
because (a) it would essentially mirror `CreateEventView` with
pre-filled fields, and (b) `EventDetailCoordinator.updateEvent` flow
needs the same wiring. The `EventHostActionsSection` calls a no-op
`onEdit` closure currently.

**Steps for V1.x**:
1. Create `EditEventView` similar to `CreateEventView` but seeded
   from `coordinator.event` and calling `eventRepo.updateEvent(_:patch:)`.
2. Wire from `EventDetailView` via `.fullScreenCover(isPresented:)`
   triggered by `onEdit`.

---

## 8. Snapshot tests

Plan called for snapshot tests of every view × {default, loading,
filled, error} × {light, dark, HC}. Deferred to V1.x (Mac required
to record baselines). Unit tests work on Linux; snapshot tests don't.

---

## 9. CheckInScannerView in simulator

Camera unavailable in iOS simulator — the scanner view shows a black
screen + console warning. Real device required for end-to-end
scanner testing.

For automated tests, consider injecting a mock `QRScannerService`
that calls `handleScan(_:)` directly with test payloads.

---

## 10. UI test rewrite

`HappyPathTests.swift` is still disabled (since onboarding V1).
Event Layer V1 hasn't added a UI test for the create-event → RSVP →
check-in flow. **Steps**:
- Re-enable HappyPathTests as the basis.
- Drive: launch with `TANDAS_USE_MOCKS=1`, complete founder
  onboarding, tap FAB, fill CreateEventView, publish, tap own RSVP
  card, set "Voy", tap "Ya llegué", verify check-in green card.

---

## Priority

1. **#1 APNs** — without this, no remote reminders/recordatorio.
2. **#5 Member lookup** — currently every attendee shows as "Member"
   in the UI. Tractable, just wiring.
3. **#3 RUUL_QR_SECRET** — needed for QR scanner to actually work
   (sign + verify must use the same secret).
4. **#7 EditEventView** — host can't edit yet (placeholder no-op).
5. **#4 Edge function deploys** — auto-close + auto-generate are
   real and ready, just need to schedule.
6. Items 2, 6, 8, 9, 10: polish, V2 work, deferred per plan.
