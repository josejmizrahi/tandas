# Anonymous Auth → Phone-Authenticated User Promotion

**Status**: ✅ IMPLEMENTED — needs testing against your Supabase project.

## Background

ruul's founder onboarding creates the group at step 2 (Group Identity) using
the anonymous user's auth.users.id. If OTP at step 5b minted a *new* user
instead of promoting the anon, every founder would lose access to their
group right after confirming their phone (RLS denies because
`is_group_admin(group_id, newPhoneUserId)` is false — group_members has the
old anon id).

This document tracks the fix.

---

## What's shipped

### iOS client

- **`AuthService.signInAnonymouslyIfNeeded()`** (default no-op + override
  in `LiveAuthService`): proactively signs in anonymously at app launch so
  every fresh launch has `auth.uid()` before reaching the founder
  onboarding step 2.
- **`AppState.start()`** calls it before entering the sessionStream loop.
- **`LiveGroupsRepository.createInitial`** has a reactive retry pattern
  (sign out → sign in anon → retry RPC) as a belt-and-suspenders fallback
  for stale-session cases.
- **`LiveOTPService`** now branches by channel:
  - **WhatsApp** path: still goes through our `send-otp` + `verify-otp`
    Edge Functions. Server validates the code (we own the code lifecycle
    via Wassenger + `otp_codes` table), then promotes the anon caller via
    `admin.updateUserById(callerId, { phone, phone_confirm: true })`.
    Same UID before and after. Client calls `auth.refreshSession()` to
    pick up the new `is_anonymous: false` claim in the JWT.
  - **SMS** path: bypasses our edge functions entirely. Uses Supabase
    Auth's canonical phone-change flow:
    `auth.update(user: UserAttributes(phone:)) → auth.verifyOTP(phone:, token:, type: .phoneChange)`.
    That flow is built specifically for anon-promotion and natively keeps
    the same UID.

### Edge Functions

- **`send-otp`**: now ONLY handles WhatsApp via Wassenger. Returns 503
  `wassenger_unconfigured` (or 502 `wassenger_send_failed`) if the
  WhatsApp path is unavailable — the iOS client falls through to the
  SMS path automatically.
- **`verify-otp`**: full rewrite. WhatsApp branch only (SMS is now
  client-side). Reads caller JWT from Authorization header, validates
  the code hash, calls `admin.updateUserById` with `phone_confirm: true`
  to promote. Returns 200 `{ ok, user_id, promoted: true }` on success,
  or typed error codes (`invalid_code`, `too_many_attempts`,
  `phone_already_used`, etc.) on failure.

### Net effect

- Founder opens app fresh → anon UID `A` is created.
- Founder onboarding creates groups + group_members rows with `created_by = A`.
- Founder confirms phone via WhatsApp → server promotes anon `A` to
  phone-authenticated. Same UID. Client refreshes JWT.
- Founder retains admin access to their group. 🎉

OR

- Founder confirms phone via SMS (because Wassenger unavailable) → Supabase
  Auth's native `phone_change` flow promotes anon `A` to phone-authenticated.
  Same UID. Same outcome.

---

## Required Supabase project configuration

To make this all work in production:

1. **Anonymous sign-ins ENABLED**:
   Dashboard → Authentication → Providers → Anonymous sign-ins → enable.
   Without this, `signInAnonymouslyIfNeeded` throws and the founder
   can't even start the onboarding.

2. **Phone provider configured** (for SMS path):
   Dashboard → Authentication → Providers → Phone → enable + configure
   Twilio (or your SMS provider). The SMS path uses Supabase's native
   integration; if disabled, only WhatsApp works.

3. **Wassenger secrets** (for WhatsApp path):
   ```
   supabase secrets set WASSENGER_API_KEY=...
   supabase secrets set WASSENGER_DEVICE_ID=...
   supabase secrets set WASSENGER_TIMEOUT_MS=5000
   ```
   Without these, `send-otp` returns 503 and the client falls through
   to SMS.

4. **Edge functions deployed**:
   ```
   supabase functions deploy send-otp verify-otp
   ```

---

## Edge cases handled

### `phone_already_used`

If the phone is already linked to a *different* user (e.g., a previous
account someone abandoned), `admin.updateUserById` errors with "Phone
already registered". The edge function returns 409 + `code: phone_already_used`.

**Current iOS behavior**: surfaces as `OTPError.invalidCode` to the user.
This means the user sees "Código incorrecto" which is wrong — they
entered the right code but the phone is just claimed.

**TODO**: extend OTPError with `.phoneAlreadyUsed` case + handle in the
coordinator to:
1. Show a clearer message ("Este número ya tiene cuenta")
2. Sign out the anon user (losing the in-progress group)
3. Route the user to a "sign in with this phone" path (not in V1.x —
   would require a second phone-OTP flow without the anon promotion)

### Caller is already phone-authenticated

If caller's JWT shows `is_anonymous: false`, the verify-otp edge function
returns `{ ok: true, promoted: false }` without touching the user record.
Defensive — shouldn't happen in normal onboarding but won't break anything.

### SMS but Supabase phone provider not enabled

`auth.update(user:)` will throw an error from the SDK. iOS surfaces as
`OTPError.sendFailed`. User sees "No pudimos enviar el código" — they
have to reach out to support.

---

## Testing plan

**Required**: a Supabase project with the configuration above.

### Happy path (WhatsApp)

1. Enable anon sign-ins + configure Wassenger.
2. Fresh app launch on a phone that has NO existing user in auth.users.
3. Verify `client.auth.session?.user.id` is `<anon_id>` and
   `is_anonymous: true` in the JWT after launch.
4. Complete founder onboarding through step 5 (group created, vocab + rules).
5. Verify `groups.created_by = <anon_id>` in DB.
6. Enter phone → tap "Enviar código" → check WhatsApp received.
7. Enter code → on success, verify:
   - `client.auth.session?.user.id == <anon_id>` (same UID)
   - `client.auth.session?.user.phone == <phone>`
   - `is_anonymous: false` in the new JWT
   - `groups.created_by` unchanged (= same anon_id, but user is now real)
   - `is_group_admin(group_id, current_user) == true`

### Happy path (SMS fallback)

1. Same as above but disable Wassenger (don't set the secrets).
2. `send-otp` returns 503; iOS falls through.
3. `auth.update(user: UserAttributes(phone:))` triggers SMS via Twilio.
4. Enter code → `auth.verifyOTP(type: .phoneChange)` succeeds.
5. Same verification as WhatsApp happy path.

### `phone_already_used`

1. Pre-create user `B` with phone `+5215555` in Supabase Dashboard.
2. Fresh launch as anon `A`. Onboard, create group.
3. At step 5, enter phone `+5215555`.
4. Verify edge function returns 409 with `code: phone_already_used`.
5. Verify iOS surfaces an error (currently generic — see TODO above).

### Stale anon session

1. Launch app as anon `A`. Wait long enough that the JWT expires.
2. Reach step 2 → `createInitial` should still work via the reactive
   retry (signs out + signs in fresh anon + retries RPC).

---

## Known limitations / future work

1. **`phone_already_used` UX is rough** (see edge case above). To fix:
   add `OTPError.phoneAlreadyUsed`, branch in the coordinator, prompt
   user to switch accounts.
2. **Anon group is lost when phone is claimed**. To preserve, we'd need
   a "merge groups" or "transfer ownership" flow — not V1 scope.
3. **`refreshSession()` only updates the JWT, not the local session object**
   in some Supabase SDK versions. iOS code may need an extra
   `try await client.auth.session` access to force a re-read.
4. **The `current_user_id` is implicit** (read from JWT) — if the
   Authorization header isn't attached automatically by supabase-swift,
   the edge function returns 401 `missing_auth`. This shouldn't happen
   because `client.functions.invoke(...)` attaches the header by default.
5. **Anonymous sign-ins disabled** in Supabase: the proactive
   `signInAnonymouslyIfNeeded` throws silently (caught with `try?`).
   Founder onboarding fails at step 2 with "create_group_with_admin: not
   authenticated". Catch this at the coordinator + surface a clear
   "Anonymous sign-ins required" message during dev.

---

## Migration story for existing users

If you already have founders in production with orphaned groups (created
under anon UIDs that got replaced by phone UIDs in the OLD verify-otp
flow), you'd need a one-time data migration:

```sql
-- Map orphaned anon UIDs → their corresponding phone UIDs based on
-- temporal correlation (group created within 5min of phone user creation).
-- Test against staging first.
update group_members gm
set user_id = pu.id
from auth.users au, auth.users pu
where gm.user_id = au.id
  and au.is_anonymous = true
  and au.created_at > now() - interval '90 days'
  and pu.phone is not null
  and pu.created_at between au.created_at and au.created_at + interval '5 minutes';

update groups g
set created_by = pu.id
where created_by in (select id from auth.users where is_anonymous = true)
  and exists (
    select 1 from auth.users pu
    where pu.phone is not null
      and pu.created_at between (select created_at from auth.users where id = g.created_by)
                            and (select created_at + interval '5 minutes' from auth.users where id = g.created_by)
  );
```

Untested — would need careful validation before running on prod data.

---

**This implementation is fresh code (Linux-built, untested against live
Supabase). First real-device test will likely surface rough edges; this
doc + commit history is the foundation for iterating.**
