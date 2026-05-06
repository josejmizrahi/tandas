# VoidFineSheet — design

**Status**: brainstormed, ready for implementation plan
**Author**: Claude (session 2026-05-06, post-AddManualFineSheet)
**Roadmap item**: Plans/UICompleteCoverage.md §4 P0 #4
**Scope**: VoidFineSheet only. OpenVotesView and EditMembersSheet are separate sprints with their own brainstorm.

## Goal

Allow a group admin (V1: founder) to annul a fine that should not have been issued — e.g. duplicated, resolved out-of-app, manual error — from `FineDetailView`. The fined user is notified via `user_actions(action_type='fineVoided')` and the action is recorded in `system_events` for audit.

## Out of scope

- VoidFineSheet entry from ReviewProposedFinesView during grace period (registered as Sprint Follow-up — needs prior audit of that view per UICompleteCoverage status).
- VoidFineSheet entry from MyFinesView swipe-action (admin sees only own fines there — edge case).
- Voiding paid fines (status guard rejects). Refunds handled out-of-app.
- Undo of void. Status `voided` is terminal; correction via new manual fine.
- Configurable governance for "voidFine" (synthetic `.founder` level in V1; jsonb field in V2).
- Admin notification when a member's fine is voided by another admin (V2 — assumes single admin per group in V1).

## Backend assumptions verified

Per the spec-process-improvement note, this section documents what was checked against actual prod state.

**`void_fine` RPC (00016_fines_v2.sql:142-163)**:

- Signature `(p_fine_id uuid, p_reason text default null)` returns `public.fines`.
- Validators: `auth.uid() not null`, `is_group_admin(f.group_id, uid)`. **No status guard.** **No reason length guard.** Both gaps closed by 00029.
- Update sets `status='voided', waived=true, waived_at=now(), waived_reason=p_reason`.
- **Emits no `user_actions` insert. Emits no `system_event`.** Fined user has zero notification today. Both gaps closed by 00029.

**`on_fine_officialized` trigger (00016_fines_v2.sql:101-128, post-00028 update)**:

- Fires on INSERT or UPDATE of status (post-00028).
- Function body emits `user_actions(action_type='finePending')` only when status flips to `'officialized'`. A flip to `'voided'` does not match, so no `finePending` is duplicated when a fine goes officialized→voided.

**Conclusion**: 4 backend deltas required. All in a single `CREATE OR REPLACE FUNCTION public.void_fine` migration (00029):

1. Status guard: reject if `status NOT IN ('proposed','officialized')`.
2. Reason guard: reject if `length(coalesce(p_reason,'')) < 2`.
3. Emit `user_actions(action_type='fineVoided', priority='normal')` for the fined user.
4. Emit `record_system_event(group_id, 'fineVoided', fine.id, ...)` for audit.

The trigger is unchanged. The `void_fine` body becomes the single source of truth for "fine got voided → notify + record". This is consistent with how `issue_manual_fine` post-00028 inserts directly with `status='officialized'` and lets the trigger emit `finePending`.

**`SystemEventType` enum (Swift):** must add `case fineVoided`. Codegen (lefthook pre-commit) regenerates `SystemEventType+Codable.swift` and the TS shared type automatically.

**`is_group_admin` source-of-truth check**: canonical = `roles` JSONB array (post-00027). Admin == founder in V1.

**`GovernanceAction` codegen exclusion**: confirmed at `scripts/codegen/README.md:37`. New case `.voidFine` does not regenerate TS.

**`FineRepository.void(fineId:reason:)` already exists** (Live + Mock from prior work). No protocol change. Mock gets a small `setThrowOnVoid(_:)` test hook + custom error message support.

## §1 — Architecture

```
ios/Tandas/
  Features/Fines/Sheets/VoidFineSheet.swift                      ← new View struct
  Features/Fines/Coordinator/VoidFineCoordinator.swift           ← new @Observable @MainActor
  Features/Fines/Views/FineDetailView.swift                      ← edit (+3 inputs, +2 @State, +1 task, +ruulSheet, +Anular button, +ANULADA section)
  Features/Events/Views/MainTabView.swift                        ← edit (fineDetailScreen wires closures)
  Platform/Models/GovernanceAction.swift                         ← +1 case .voidFine
  Platform/Models/GovernanceRules.swift                          ← +1 synthetic case in level(for:)
  Platform/Models/SystemEventType.swift                          ← +1 case .fineVoided (codegen-managed)
  Platform/Repositories/FineRepository.swift                     ← edit (Mock setThrowOnVoid + custom error)

ios/TandasTests/
  Fines/VoidFineCoordinatorTests.swift                           ← new (~10 tests)
  Platform/GovernanceServiceTests.swift                          ← +2 tests symmetric to .issueManualFine

supabase/migrations/
  00029_void_fine_guards_and_emit.sql                            ← new (single CREATE OR REPLACE)
  00029_void_fine_guards_and_emit_rollback.sql                   ← new (restores 00016 body)
```

**Architectural decision (locked):** governance + repos reach FineDetailView via two closures injected by MainTabView (matching the AddManualFineSheet pattern from 2026-05-06). `FineDetailCoordinator`'s API stays unchanged. The closures capture `app.governance`, `app.fineRepo`, `app.groupsRepo` and the user id.

**Cross-group complication:** fines may be from any group the user belongs to (MyFinesView is cross-group). The `computeCanVoidFine` closure resolves the user's `Member` row in `fine.groupId` via `groupsRepo.membersWithProfiles(of:)` before running the governance check. Cost: one extra round-trip per FineDetailView open. Acceptable — FineDetailCoordinator already loads async on `.task`.

**Migration 00029 — single `CREATE OR REPLACE FUNCTION`:**

```sql
create or replace function public.void_fine(p_fine_id uuid, p_reason text default null)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if not public.is_group_admin(f.group_id, uid) then
    raise exception 'only admins can void fines';
  end if;
  -- New guards (00029):
  if f.status not in ('proposed','officialized') then
    raise exception 'cannot void fine with status %', f.status;
  end if;
  if length(coalesce(p_reason, '')) < 2 then
    raise exception 'reason required';
  end if;

  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;

  -- New emissions (00029):
  insert into public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) values (
    f.user_id, f.group_id, 'fineVoided', f.id,
    'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
    p_reason,
    'normal'
  );

  perform public.record_system_event(
    f.group_id,
    'fineVoided',
    f.id,
    null,
    jsonb_build_object('amount', f.amount, 'reason', p_reason)
  );

  return f;
end;
$$;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.void_fine(uuid, text) to authenticated;
```

Rollback: `CREATE OR REPLACE` with the 00016 body verbatim (no guards, no emissions).

## §2 — Components

**1. `VoidFineSheet` (View)** — `Features/Fines/Sheets/VoidFineSheet.swift`

Wraps `ModalSheetTemplate(title: "Anular multa", dismissAction: ...)`. Layout:

```
┌──────────────────────────────────────────┐
│ Anular multa                  [✕]        │
├──────────────────────────────────────────┤
│ MULTA                                    │
│ ┌──────────────────────────────────┐     │
│ │ Ana López — $200                 │     │   read-only context card
│ │ "Llegó tarde sin avisar"         │     │
│ └──────────────────────────────────┘     │
│                                          │
│ MOTIVO DEL ANULADO                       │
│ ┌────────────────────────────┐           │
│ │ Multa duplicada            │           │   RuulTextField
│ └────────────────────────────┘           │
│ Visible para Ana.                        │   caption helper, dynamic name
│                                          │
│ [error callout if any]                   │
│                                          │
│ [    Anular multa    ]                   │   destructive style, fillsWidth
└──────────────────────────────────────────┘
```

Inputs: `@Binding isPresented: Bool`, `@Bindable coordinator: VoidFineCoordinator`. View renders state, dispatches `coordinator.submit()`. Helper text uses `RuulTypography.caption` + `Color.ruulTextTertiary`. Error rendered without inline padding (parent VStack of ModalSheetTemplate already applies `RuulSpacing.s5`).

**2. `VoidFineCoordinator`** — `Features/Fines/Coordinator/VoidFineCoordinator.swift`

```swift
@Observable @MainActor
final class VoidFineCoordinator {
    let fine: Fine

    private(set) var targetMemberName: String = "el multado"
    var reason: String = ""
    private(set) var isSubmitting: Bool = false
    private(set) var error: String?

    private let fineRepo: any FineRepository
    private let groupsRepo: any GroupsRepository

    init(fine: Fine, fineRepo: any FineRepository, groupsRepo: any GroupsRepository)

    var canSubmit: Bool {
        !isSubmitting &&
        reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    func resolveTargetName() async
    @discardableResult
    func submit() async -> Fine?
    private func humanize(error: Error) -> String
}
```

`resolveTargetName` calls `groupsRepo.membersWithProfiles(of: fine.groupId)`, finds row matching `fine.userId`, sets `targetMemberName` to `displayName`. Falls back to `"el multado"` on lookup failure (logged warning, no UI error).

`submit` calls `fineRepo.void(fineId: fine.id, reason: reason.trimmed)`, returns Fine or nil + error.

`humanize` mapping in §4.

**3. `FineRepository` modifications**

- `MockFineRepository`: add `private var throwOnVoid: Bool = false` + `private var voidErrorMessage: String = "only admins can void fines"`. Public setters `setThrowOnVoid(_:)` and `setVoidErrorMessage(_:)`. Existing `void(fineId:reason:)` body honors the flag.

- `LiveFineRepository.void`: unchanged (already calls `void_fine` RPC with the right params).

- Protocol surface unchanged.

**4. `FineDetailView` modifications**

Three new `let` inputs:
```swift
let computeCanVoidFine: () async -> Bool
let makeVoidFineCoordinator: () -> VoidFineCoordinator
let currentUserId: UUID
```

Two new `@State`:
```swift
@State private var voidSheetPresented = false
@State private var canVoidFine: Bool = false
```

New `.task` after existing tasks:
```swift
.task { canVoidFine = await computeCanVoidFine() }
```

New `.ruulSheet` near other sheet modifiers:
```swift
.ruulSheet(isPresented: $voidSheetPresented) {
    // Fresh coordinator per open: makeVoidFineCoordinator() runs each time
    // the binding flips false→true. Deliberate — avoids leaking partial form
    // state from cancelled sessions.
    VoidFineSheet(
        isPresented: $voidSheetPresented,
        coordinator: makeVoidFineCoordinator()
    )
}
```

Footer modifications: add a new `actionsForAdmin` section that renders alongside (not instead of) `actionsForMyFine`. The destructive button shows when:
- `!coordinator.isMine` AND
- `canVoidFine` AND
- `coordinator.fine.status == .proposed || .officialized`

```swift
@ViewBuilder
private var actionsForAdmin: some View {
    if !coordinator.isMine, canVoidFine,
       coordinator.fine.status == .proposed || coordinator.fine.status == .officialized {
        RuulButton("Anular multa", style: .destructive, size: .large, fillsWidth: true) {
            voidSheetPresented = true
        }
        .padding(.horizontal, RuulSpacing.s5)
        .padding(.vertical, RuulSpacing.s3)
        .background(.regularMaterial)
    }
}
```

`actionFooter` body composes `actionsForMyFine` and `actionsForAdmin` (only one renders at any time given the gate logic).

New body section between `evidenceSection` and `appealStatusInline`:
```swift
@ViewBuilder
private var voidedSection: some View {
    if coordinator.fine.status == .voided,
       let waivedReason = coordinator.fine.waivedReason,
       !waivedReason.isEmpty {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("ANULADA POR ADMIN")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(waivedReason)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .padding(RuulSpacing.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
                )
        }
    }
}
```

**5. `MainTabView.fineDetailScreen(_:)`** — wires closures

```swift
private func fineDetailScreen(_ fine: Fine) -> some View {
    let coord = FineDetailCoordinator(
        fine: fine,
        userId: app.session?.user.id ?? UUID(),
        fineRepo: app.fineRepo,
        appealRepo: app.appealRepo
    )
    let userId = app.session?.user.id ?? UUID()
    let governance = app.governance
    let fineRepo = app.fineRepo
    let groupsRepo = app.groupsRepo
    let groups = app.groups

    return FineDetailView(
        coordinator: coord,
        onAppeal: nil,
        onViewAppeal: { appeal in
            voteOnAppealRoute = AppealRouteContext(appeal: appeal, fine: fine)
        },
        computeCanVoidFine: {
            guard let group = groups.first(where: { $0.id == fine.groupId }) else { return false }
            do {
                let rows = try await groupsRepo.membersWithProfiles(of: fine.groupId)
                let me = rows.first(where: { $0.member.userId == userId })?.member
                    ?? Member(
                        id: UUID(), groupId: fine.groupId, userId: userId,
                        role: "member", roles: [.member], active: false, joinedAt: .now
                    )
                let decision = try await governance.canPerform(.voidFine, member: me, in: group, context: nil)
                if case .allowed = decision { return true }
                return false
            } catch { return false }
        },
        makeVoidFineCoordinator: {
            VoidFineCoordinator(fine: fine, fineRepo: fineRepo, groupsRepo: groupsRepo)
        },
        currentUserId: userId
    )
}
```

**6. `GovernanceAction.voidFine` + level**

```swift
// GovernanceAction.swift
case voidFine = "whoCanVoidFines"
```
```swift
// GovernanceRules.level(for:)
case .voidFine: return .founder    // synthetic V1; no jsonb field yet
```

**7. `SystemEventType.fineVoided`**

Add `case fineVoided` to the Swift enum. Codegen lefthook regenerates `SystemEventType+Codable.swift` automatically. Verify the regenerated file uses raw value `"fineVoided"` to match the SQL emission.

## §3 — Data flow

**Sheet open:**

```
FineDetailView.onAppear
  └─ task { canVoidFine = await computeCanVoidFine() }
      ├─ groupsRepo.membersWithProfiles(of: fine.groupId)
      ├─ resolve user's Member in that group (or fallback inactive)
      └─ governance.canPerform(.voidFine, member, in: group)

FineDetailView body
  └─ if canVoidFine && fine.status ∈ {.proposed, .officialized} && !isMine
      └─ "Anular multa" destructive button [tap]
          └─ voidSheetPresented = true

.ruulSheet { VoidFineSheet(coordinator: makeVoidFineCoordinator()) }
  └─ .task { await coordinator.resolveTargetName() }

VoidFineCoordinator.resolveTargetName
  ├─ groupsRepo.membersWithProfiles(of: fine.groupId)
  ├─ find row where member.userId == fine.userId
  └─ targetMemberName = row.displayName (or "el multado" on failure)
```

**Submit:**

```
VoidFineSheet [tap "Anular multa"]
  └─ coordinator.submit()
      ├─ guard canSubmit
      ├─ isSubmitting = true; error = nil
      ├─ try fineRepo.void(fineId: fine.id, reason: reason.trimmed)
      │   └─ LiveFineRepository.rpc("void_fine", params: { p_fine_id, p_reason })
      │       └─ server: status guard + reason guard + UPDATE + user_action(fineVoided) + record_system_event(fineVoided)
      ├─ on success: isSubmitting=false; haptic .success; isPresented=false
      └─ on failure: isSubmitting=false; error=humanize(...); form preserved
```

**Visibility for fined user (other session):**

`user_actions(fineVoided)` row → ActionInboxView shows "Multa anulada por admin: $200"; MyFinesView puts the fine in "Resueltas" tab with tertiary status dot. Tap → FineDetailView shows "ANULADA POR ADMIN" section with `waived_reason`.

**Same-admin refresh:** FineDetailCoordinator's `.task` re-runs on view re-render after sheet closes. Fine state updates. Buttons hide. ANULADA section appears.

## §4 — Error handling y validación

**Client validation:**

| Field | Rule | UX |
|---|---|---|
| Reason | trimmed.count >= 2 | CTA disabled |
| Submit lock | !isSubmitting | CTA `"Anulando…"` with spinner |

CTA label: always `"Anular multa"` (not dynamic). When submitting → `"Anulando…"`.

**Server error mapping (`humanize`):**

| Server raise | UI message |
|---|---|
| `not authenticated` | `"Tu sesión expiró. Volvé a entrar."` |
| `only admins can void fines` | `"Solo admins pueden anular multas."` |
| `cannot void fine with status` | `"Esta multa ya no se puede anular (estado: \(fine.status.displayLabel))"` |
| `reason required` | `"Escribe un motivo (al menos 2 caracteres)."` |
| `fine not found` | `"Esta multa ya no existe."` |
| network/timeout/decode | `"No pudimos anular la multa. Intenta de nuevo."` |

Error rendering: `Text(error)` with `RuulTypography.caption` + `Color.ruulSemanticError`, NO inline `padding` (parent ModalSheetTemplate VStack already applies s5).

**Visual states:**

- Loading targetMemberName: name fallback = "el multado" until resolved. No blocking.
- Idle: CTA destructive, disabled until canSubmit.
- Submitting: text field `isDisabled=true`. CTA `isLoading=true`, label "Anulando…".
- Error post-submit: form re-enabled, error visible, CTA enabled for retry.
- Success: sheet closes, haptic. FineDetailView refresh shows "ANULADA POR ADMIN".

**Edge cases out of scope V1:**

- Race against active appeal (`status='in_appeal'`): falls into status guard catch-all, surfaces as error string. No special UX.
- Voiding paid: blocked at status guard. Refunds out-of-app.
- Undo of void: not implemented. Use `issue_manual_fine` for restitution.

## §5 — Testing

**Unit tests** (`Tests/VoidFineCoordinatorTests.swift`, XCTest, mock-based, `@MainActor`):

- `resolveTargetName_setsNameFromGroup`
- `resolveTargetName_fallsBackOnLookupFailure`
- `canSubmit_falseWhenReasonEmpty`
- `canSubmit_falseWhenReasonTooShort` (trimmed=1)
- `canSubmit_trueWhenReasonValid`
- `submit_callsRepoWithCorrectParams` — verify fineId, trimmed reason, returned Fine has status=.voided + waivedReason set
- `submit_setsErrorOnRepoFailure`
- `submit_clearsErrorOnRetry`
- `submit_humanizesStatusGate` — set MockFineRepo error message to "cannot void fine with status paid", assert UI message contains "ya no se puede anular"
- `submit_blocksDoubleTap`

`MockFineRepository` gains `setThrowOnVoid(_:)` + `setVoidErrorMessage(_:)`.

**`GovernanceServiceTests.swift`** — add 2 cases:

- `testCanPerformVoidFine_allowedForFounder`
- `testCanPerformVoidFine_deniedForNonFounder`

**Integration tests (deno, local-only):** optional. `Tests/Edge/void_fine_test.ts`:

- Happy path: status='voided', waived=true, waived_reason set, user_action(fineVoided) row exists, system_event(fineVoided) row exists.
- Non-admin rejected.
- Status guard rejects paid/voided/in_appeal.
- Reason guard rejects null/empty/single-char.

**Smoke manual (mandatory before merge):**

1. Admin opens proposed fine → "Anular multa" destructive button visible.
2. Tap → VoidFineSheet opens. MULTA card shows "[Name] — $[amount]" + original reason. Helper "Visible para [Name]."
3. Empty reason → CTA disabled.
4. Single char → CTA disabled.
5. "Duplicada" → CTA enabled.
6. Tap → spinner → "Anulando…" → sheet closes → haptic.
7. FineDetailView refreshes → status dot tertiary, no Pagar/Apelar/Anular buttons, "ANULADA POR ADMIN" section with reason.
8. Switch to fined user: ActionInboxView "Multa anulada por admin: $200" with body "Duplicada". MyFinesView in "Resueltas" tab with tertiary dot. Tap fine → ANULADA section visible.
9. Admin opens paid fine → "Anular multa" NOT visible (status gate).
10. Admin opens voided fine → "Anular multa" NOT visible. ANULADA section visible.
11. Regular member opens proposed/officialized fine → "Anular multa" NOT visible (canPerform gate).

**Build gate:**
```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Must print `BUILD SUCCEEDED`.

**Migration gate:** 00029 + rollback apply clean in local. Both committed. Apply to prod via Supabase MCP in authenticated session before shipped tag (same flow as 00028).

**Codegen gate:** `make gen` regenerates `SystemEventType+Codable.swift` to include `fineVoided`. Confirm any TS consumer (cron jobs, edge functions) handles the new case.

## DoD

- [ ] Migration 00029 + rollback applied locally clean.
- [ ] `GovernanceAction.voidFine` case + synthetic level + 2 tests.
- [ ] `SystemEventType.fineVoided` case + codegen run.
- [ ] `VoidFineCoordinator` + 10 tests passing.
- [ ] `VoidFineSheet` rendering all visual states.
- [ ] `FineDetailView` renders Anular button + ANULADA section per status.
- [ ] `MainTabView.fineDetailScreen` wires closures.
- [ ] `xcodebuild build` green for `generic/platform=iOS`.
- [ ] Smoke manual covers all 11 scenarios.
- [ ] Migration applied to prod (`fpfvlrwcskhgsjuhrjpz`) via Supabase MCP.
- [ ] Roadmap Fase 0 #5 updated to mark VoidFineSheet ✅, tally → 4 of 5.

## Follow-ups (registered, not blocking)

- **VoidFine entry from ReviewProposedFinesView during grace period** — natural ergonomic expansion. Deferred until (a) ReviewProposedFinesView audit completes (currently 🟡 in UICompleteCoverage) and (b) real testing shows admin needs batch void during 24h grace. Cost: ~30 min if VoidFineSheet is reusable.
- **VoidFine swipe-action on MyFinesView** — only relevant if admin sees own fines and wants to void self. Edge case, low priority.
- **Refund/rebate flow for paid fines** — out of scope V1. Handle via separate ledger feature when Tandas Phase 3 lands (per Roadmap §5 D3).
- **Notification to admins when another admin voids** — V2 once multi-admin lands (currently single founder == admin).
- **Real-time refresh** — FineDetailView doesn't subscribe to fine updates. If UX feels stale, add realtime sub via supabase channels. Bigger change.
- **Race against in-flight appeal** — current behavior: status guard rejects with generic message. UX improvement: detect "in_appeal" at canVoidFine time and hide button. Defer.
