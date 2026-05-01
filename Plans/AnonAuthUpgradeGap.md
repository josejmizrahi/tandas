# Anonymous Auth → Phone-Authenticated User Promotion

**Status**: BLOCKER for shipping V1 to real users.
**Affects**: `verify-otp` edge function + `LiveOTPService.verifyCode`.

## What's already done

| Item | Status |
|---|---|
| Anonymous sign-ins enabled in Supabase | TODO (Dashboard toggle by you) |
| Reactive anon-signin retry in `LiveGroupsRepository.createInitial` | ✅ done |
| Proactive anon-signin at app launch (`AuthService.signInAnonymouslyIfNeeded`) | ✅ done |

## What's still broken

The founder onboarding flow:

1. App launches → `AppState.start()` calls `signInAnonymouslyIfNeeded()` →
   user gets anon UID `A`.
2. Founder fills name → reaches step 2 (Group Identity).
3. Coordinator calls `groupRepo.createInitial(draft)` → RPC creates
   `groups` row with `created_by = A` and `group_members` row with
   `user_id = A, role = 'admin'`.
4. Steps 3–4: vocab + rules → updates the group as `A` (RLS allows
   because `is_group_admin(group_id, A)` is true).
5. Step 5b: founder enters phone → `LiveOTPService.requestCode(phone)`.
6. Step 5b confirms OTP → `LiveOTPService.verifyCode(...)`.
7. **Problem**: `verify-otp` edge function calls
   `auth.admin.createUser({ phone, phone_confirm: true })` which mints a
   **brand new user** with UID `B`, then issues a session for `B`.
8. App now has session for `B`. Anon user `A` is orphaned.
9. RLS check on the user's own group: `is_group_admin(groupId, B)` → false.
10. Founder loses access to the group they just created.

## What needs to happen

The OTP verify flow must **promote** anon user `A` to be the
phone-authenticated user (same UID, just adds the phone). Supabase
Auth Admin API supports this via `admin.updateUserById(A, { phone, phone_confirm: true })`.

## Proposed fix — edge function rewrite

`supabase/functions/verify-otp/index.ts` needs:

```typescript
// Request body adds an optional `current_user_id` that the iOS client
// sends as the anon user's id from the active session.
{ phone, code, channel, current_user_id?: string }

// Server flow:
async function verifyWhatsApp(phone, code, currentUserId) {
  // 1. Validate code hash (existing logic)
  // 2. Determine target user:
  let targetUserId: string;
  if (currentUserId) {
    const { data: caller } = await admin.auth.admin.getUserById(currentUserId);
    if (caller?.user && !caller.user.phone && !caller.user.email) {
      // Caller is an anon user → promote it.
      const { data: updated, error } = await admin.auth.admin.updateUserById(
        currentUserId,
        { phone: phone.replace("+", ""), phone_confirm: true }
      );
      if (error) {
        // Phone may already be claimed by a different user — fallback to
        // existing-user lookup below.
        targetUserId = await findOrCreate(phone);
      } else {
        targetUserId = currentUserId;
      }
    } else {
      // Caller is already phone/email-authenticated; treat as re-verify.
      targetUserId = currentUserId;
    }
  } else {
    targetUserId = await findOrCreate(phone);
  }
  // 3. Mint session via the magiclink workaround (existing pattern).
  return mintSession(targetUserId);
}
```

Same pattern for the SMS branch — replace the call to anon
`auth.verifyOtp({ phone, token, type: 'sms' })` with a manual flow that
checks for an anon caller and promotes via `updateUserById`.

## iOS client changes

`LiveOTPService.verifyCode(phoneE164:code:channel:)`:

```swift
func verifyCode(...) async throws {
  let currentUserId = (try? await client.auth.session)?.user.id

  struct Body: Encodable {
    let phone: String
    let code: String
    let channel: String
    let current_user_id: String?  // NEW
  }
  // ... rest same as today
}
```

## Edge cases to handle

1. **Phone already claimed by another user**: e.g., user `A` is anon,
   user `B` has phone `+5215555` from before. When anon `A` tries to
   verify same `+5215555`, `updateUserById(A, {phone})` fails with
   "phone already in use". Fallback: discard anon user `A`, sign in as
   existing `B`, accept that the in-progress group draft is lost.
   Surface a warning to the user: "Este teléfono ya tiene una cuenta —
   se cargó tu información existente."

2. **Anon → group → user logs out → user comes back**: anon UID is
   gone, group is orphaned. Mitigation: don't allow anon signOut from
   the UI until OTP completes. (Already true — the only signOut is in
   `verify-otp` retry flow which immediately signs in anon again.)

3. **Race: anon user creates group then OTP fails 3 times** → token
   becomes too-many-attempts → retry with a new anon? No — keep the
   same anon UID. The group is still owned by it. User can retry OTP
   later in the same session.

## Testing plan (when implementing)

Run against a fresh Supabase project (NOT prod):

1. Enable anonymous sign-ins.
2. Set `WASSENGER_API_KEY` + `WASSENGER_DEVICE_ID` (or skip WhatsApp →
   SMS-only path).
3. Test happy path: launch app → onboard founder → OTP → verify
   `groups.created_by` matches `auth.users.id` after promotion.
4. Test phone-claimed: pre-create a user with same phone via Auth
   admin → onboard a NEW anon → OTP → verify the existing user wins,
   anon's group is correctly cleaned up (or transferred — TBD policy).
5. Test SMS-only branch (Wassenger disabled) — same scenarios.

## Why I'm not implementing this now

The promotion flow has 3 nontrivial things that all need real Supabase
API testing:
- `auth.admin.updateUserById` behavior when phone is already claimed
- Magiclink workaround compatibility with promoted users vs new users
- Session refresh on the iOS client after the user id "stays the same"
  but tokens change

I can write the code from Linux but it's high risk of subtle bugs that
only surface against a real auth backend. Recommend: I write a draft
branch that you test against your Supabase project (or a branch
project) and we iterate from real failures.

---

**To unblock shipping, this followup is the #1 priority after Tier 2
features (rule engine, balance) — without it, every founder loses
access to their group right after OTP.**
