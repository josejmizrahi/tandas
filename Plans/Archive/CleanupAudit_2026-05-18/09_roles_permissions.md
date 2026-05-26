# Ruul Roles and Permissions Audit (2026-05-18)

## 1. Permission model status

**Mostly converged to single-source-of-truth, with residual local-eval debt.** Per `Plans/Active/RolesRemediation_2026-05-17.md` lines 17-33, Sprints A through F.7 are marked APPLIED 2026-05-17 — covering server-side guards (B), iOS `MemberRole.admin` cleanup (A), RPC re-gating onto `has_permission` (C, mig 00291), edge-function authz holes (D, mig 00298), and Swift `GovernanceService` RPC wiring (E). Critically, `is_group_admin` itself was rewritten in mig 00301 to delegate to `has_permission(modifyGovernance)`, so the ~50 RLS policies still naming `is_group_admin` now inherit the canonical resolver transparently. Mig 00322 then dropped the legacy `gm.role` text fallback from `has_permission`.

What remains:
- iOS still has TWO permission resolvers running in parallel: `GovernanceService.hasPermission` (now correctly calls server RPC with 30s cache, `GovernanceService.swift:112-149`) and a local catalog walker duplicated in 4+ coordinators (`GroupHomeCoordinator.hasPermission`, `MembersCoordinator.permission`, `MoneySectionView.viewerIsAdmin`, `ResourceDetailSheet.canCreateRules`). The server-RPC path is only used by `governance.canPerform(...)` callsites; local resolvers still ship.
- `has_permission` itself still hardcodes the `admin → founder` alias at `00322:68-70`. The audit said this should die once 00290 backfilled `admin` into every founder's roles; the alias is now redundant but lingers.

## 2. Direct role-check violations in Swift (top 15)

| # | File:Line | Issue | Classification |
|---|---|---|---|
| 1 | `RuulFeatures/.../GroupHomeCoordinator.swift:51-53` | `isCurrentUserAdmin` reads `myRawRoles.contains("admin") || myRole == "admin" || myRole == "founder"` — three competing checks for one concept | DOCTRINAL VIOLATION |
| 2 | `RuulFeatures/.../GroupHomeCoordinator.swift:18,70` | `myRole: String?` field with `"founder"/"member"/"admin"` legacy fallback still present | TRANSITIONAL DEBT |
| 3 | `RuulFeatures/.../VoteDetailCoordinator.swift:46-48` | `isCurrentUserAdmin = myRole == "founder" || myRole == "admin"` — bare string equality | DOCTRINAL VIOLATION |
| 4 | `RuulFeatures/.../EventDetailCoordinator.swift:24,57,201,234,250,291,348,438` | `viewerRole: ViewerRole` (host vs guestRole) gates 6 mutation methods purely on host equality | TRANSITIONAL DEBT |
| 5 | `RuulFeatures/.../EventDetailCoordinator.swift:234` | `viewerRole == .host \|\| event.createdBy == userId` — creator identity used as authz | DOCTRINAL VIOLATION |
| 6 | `RuulFeatures/.../EventDetailHost.swift:254-263` | `isAdmin = me?.isAdmin == true; canCreate: isAdmin || isHost` — should be `hasPermission(.modifyRules)` | DOCTRINAL VIOLATION |
| 7 | `RuulCore/.../GovernanceService.swift:246` | `member.roles.contains(.treasurer) ? .allowed : .denied(.notTreasurer)` — enum equality, ignores catalog | DOCTRINAL VIOLATION |
| 8 | `RuulCore/.../GovernanceService.swift:224` | `member.isFounder ? .allowed : .denied(.notFounder)` for `.founder` level — identity, not permission | DOCTRINAL AMBIGUITY (V27) |
| 9 | `RuulFeatures/.../MoneySectionView.swift:280-298` | Local catalog walk for `viewerIsAdmin`; comment says "consistent with mig 00291" but duplicates the resolver | TRANSITIONAL DEBT |
| 10 | `RuulFeatures/.../ResourceDetailSheet.swift:260-269` | `canCreateRules` re-implements local catalog walk for `.modifyRules` | TRANSITIONAL DEBT |
| 11 | `RuulCore/.../Member.swift:127-129` | `isAdmin` getter is stable-ish (`holdsRole("admin")`) but its 19 callsites treat it as a global gate | TRANSITIONAL DEBT |
| 12 | `RuulFeatures/.../MembersCoordinator.swift:79` | `isCurrentUserAdmin` shipped even though `canManageRoles`/`canRemoveMembers` (correct) exist | TRANSITIONAL DEBT |
| 13 | `RuulFeatures/.../LeaveGroupConfirmationSheet.swift:19-27` | `isSoleAdmin` = `members.filter { $0.member.isAdmin &&  $0.member.active }.count == 1` — should count "members with `.modifyGovernance`" | DOCTRINAL VIOLATION |
| 14 | `RuulFeatures/.../AddManualFineSheet.swift:73-77` | Shows label `"ADMIN"` when `mwp.member.isFounder` — **mislabels founder as admin in the UI** | DOCTRINAL VIOLATION (founder/admin confusion) |
| 15 | `RuulCore/.../CapabilityResolver+SecondaryActions.swift:57-99` | Legacy `viewerRole: MemberRole` overload still wired with `legacyPermissions(for:)` static map; coordinators likely feed it instead of `viewerPermissions:` canonical | TRANSITIONAL DEBT (deprecation pending) |

Other notable: `Group.swift:238,245` and `GroupsRepository.swift:644-651` still produce a `myRole: String` legacy field. `has_permission` itself (mig 00322:68-70) still does `admin → founder` aliasing.

## 3. Direct role-check violations in edge functions

| File:Line | Issue |
|---|---|
| `process-system-events/index.ts:473-485` | `listMembersWithRole` reads `group_members.roles ? role_id` directly — by design (engine target selector `$role.<role_id>`). Audit V7 (DOCTRINAL VIOLATION architectural) — label-only, kept post Sprint F.3. |
| `process-system-events/index.ts:541-552` | `loadMemberRoles` reads `group_members.roles` jsonb directly — used by `actorHasRole` rule-engine condition (label evaluation). Same V7 caveat. |
| `_shared/ruleEngineConditions.ts:182-192` | `actorHasRole` condition compares role label, not permission. Kept-and-flagged (F.3); a parallel `actorHasPermission` was added. |

Heresies V5 (`send-event-notification`) and V6 (`process-system-events` founder hardcode) are **CLOSED** per the function bodies — `send-event-notification/index.ts:64-127` now requires JWT + `has_permission(manageEvents)` for `cancelled`. `create-placeholder-member/index.ts:64-75` correctly gates via `has_permission(modifyMembers)`.

## 4. RLS policies bypassing has_permission

Mig 00002 RLS (`groups_update_admin`, `groups_delete_admin`, `members_update_admin`, `rules_update_admin`, `events_delete_admin`, plus ~50 more) **still text-name `is_group_admin(...)`**, but mig 00301 made `is_group_admin` a one-line wrapper around `has_permission(gid, uid, 'modifyGovernance')`. Net: every RLS policy now resolves via the canonical resolver. No RLS hardcodes `'admin'` / `'founder'` strings.

Residual concern: `members_update_admin` still allows direct UPDATE of `group_members.*` rows — column-level guard for `roles` writes now sits in mig 00280's trigger (`group_members_roles_guard`), so the doctrinal hole V1 is closed at the trigger layer rather than the RLS layer.

## 5. has_permission gaps

The 27-permission catalog (founded mig 00063, expanded through 00255) is materially complete for Beta 1. Confirmed gaps still per the audit §H, not yet closed:
- **`lockFund`** / **`unlockFund`** — audit recommended dedicated perms; mig 00291 reuses `modifyGovernance` (comment line 24 acknowledges freeze defers this).
- **`manageBookings`** — audit recommended for space admin RPCs; mig 00291 reuses `modifyGovernance` (line 22-25).
- **`finalizeVote`** — V13 explicitly deferred (00291 header line 19-21); `finalize_vote` still does `gm.roles ?| array['founder']` lookup at mig 00148:636 and 00150:862.
- **`hostEvent` / `assignHost`** — no permission entry; host assignment uses contextual `event.host_id` (correct doctrine, not a gap).

## 6. Owner / admin / host confusion

Concrete current-day confusions:
- `AddManualFineSheet.swift:73-77` literally renders the label "ADMIN" when `member.isFounder`. Wrong concept.
- `EventDetailHost.swift:254-256` comments "requiere permission, no identity" then proceeds to `me?.isAdmin == true`, which is the local jsonb check, not the server RPC.
- `EventDetailCoordinator.swift:234` mixes `viewerRole == .host` (contextual) with `event.createdBy == userId` (identity) as an OR — creator-survives-handoff semantics quietly leak.
- `LeaveGroupConfirmationSheet.swift:19-27` counts "isAdmin" holders for `isSoleAdmin`, but the audit says the correct count is "members holding `.modifyGovernance`" so custom roles count.
- `GroupHomeCoordinator.swift:51` triple-or `myRawRoles.contains("admin") || myRole == "admin" || myRole == "founder"` — three concepts glued together.
- "Owner" does not exist in code — clean. No `adminIds` field exists either. The remaining ambiguity is V27 (founder identity vs founder role) which is documented in `Plans/Active/V27_FounderIdentity_doctrine.md` as deferred.

## 7. Remediation plan progress (claimed vs reality)

`RolesRemediation_2026-05-17.md` claims all 14 sprint rows APPLIED 2026-05-17 except F (cleanup tail). Verified:

- Sprint B (mig 00285-00288): triggers + `groupRolesChanged` whitelist present. Real.
- Sprint C (mig 00291): `transfer_right`, `delegate_right`, `fund_lock/unlock`, `archive_group/resource`, `grant/revoke_space_access` all now call `has_permission(...)`. Real.
- Sprint E (Swift): `GovernanceService.swift:112-149` does call server RPC. Real. BUT cleanup of local-resolver duplication in `GroupHomeCoordinator`, `MembersCoordinator`, `MoneySectionView`, `ResourceDetailSheet` was NOT done.
- Sprint F.1 (mig 00299, 00303): `is_group_admin` reads jsonb, `group_members.role` text column dropped. Real.
- Sprint F.4 (mig 00301): `is_group_admin` delegates to `has_permission(modifyGovernance)`. Real.
- F.7 (V27 founder identity): doctrine doc written, implementation deferred. Real.

Drift from plan: "Sprint F cleanup tail" (eliminate legacy text, formalize `public.permissions` table, full Phase 5 RLS rewire) is still pending — not Beta-blocking because mig 00301 already routes every RLS through `has_permission`.

## 8. Beta blockers

None doctrinal. The three HERESIES from the audit (V1+V2 role write holes, V3 transfer_right text gate, V5 send-event-notification no-auth) are **all closed**. What remains:

- **Cosmetic / UX bug (should fix)**: `AddManualFineSheet.swift:73-77` labels founders as "ADMIN" — confuses identity vs capability in the user's face.
- **Latent stale-cache footgun**: `GovernanceService` 30s TTL with no invalidation hooks on `assign_role`/`unassign_role`. Acceptable for Beta, known follow-up.
- **Local-resolver duplication** in 4 iOS files = mild Wet-DRY violation; semantics agree today but will drift the moment server-side `has_permission` semantics shift (e.g. if alias `admin → founder` at mig 00322:68-70 is finally removed).
- **`finalize_vote` V13** still does direct jsonb founder lookup; safe but inconsistent.

Net assessment: Beta-1 unblocked on the auth/permission axis.
