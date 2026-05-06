# AddManualFineSheet — design

**Status**: brainstormed, ready for implementation plan
**Author**: Claude (session 2026-05-06)
**Roadmap item**: Plans/UICompleteCoverage.md §4 P0 #3
**Scope**: AddManualFineSheet only. VoidFineSheet is its own future spec.

## Goal

Allow a group admin (V1: founder) to issue a fine to a group member ad-hoc — outside the rule engine — from the event detail screen. The fine should be immediately visible to the fined member (officialized, no 24h grace) and follow the project's governance abstraction.

## Out of scope

- VoidFineSheet (separate sprint, separate brainstorm).
- Rule preselection inside the sheet (`p_rule_id` always NULL in V1).
- Cross-event entry points (no entry from FineDetailView, ProfileView, GroupInfoSheet).
- Configurable governance for "issueManualFine" (synthetic `.founder` level in V1; jsonb field added when V2 makes it user-editable).
- Offline submit / retry queue.
- Duplicate-issue deduplication.

## Backend assumptions verified

Per the spec-process-improvement note from `Plans/UICompleteCoverage.md` (P0 #1 follow-up), this section documents what was checked against actual prod state, not assumed.

**`issue_manual_fine` RPC (00008_phase4_5_anti_tirania.sql:195-236)**:

- Signature `(p_group_id uuid, p_user_id uuid, p_amount numeric, p_reason text, p_rule_id uuid, p_event_id uuid)` returns `public.fines`.
- Validators: `auth.uid() not null`, `is_group_admin(p_group_id, auth.uid())`, `is_group_member(p_group_id, p_user_id)`, `p_amount >= 0`, `length(coalesce(p_reason, '')) >= 2`.
- Insert sets `auto_generated=false`, `issued_by=auth.uid()`. Does **not** set `status` explicitly → falls through to column default `'proposed'` (00016_fines_v2.sql:23).
- Snapshots rule into `rule_snapshot` jsonb if `p_rule_id` provided.

**`on_fine_inserted` trigger (00016_fines_v2.sql:58)**:

- Fires `if new.auto_generated and new.status = 'proposed'`. Manual fines (auto_generated=false) **bypass it** — no `fine_review_periods` row, no `fineProposalReview` user_action.
- Comment in 00016:64-65 says manual fines "bypass [grace] (host is the sole reviewer)". Implementation never closes the cycle: manual fine sits at status='proposed' forever, no `finePending` user_action emitted, fined user has no UI visibility.

**`on_fine_status_change` trigger (00016_fines_v2.sql:?)**: fires `finePending` user_action when status flips to `'officialized'`.

**Conclusion**: backend has a latent bug. Manual fines are silently invisible to the fined user. Fix is required for AddManualFineSheet to be functional. Migration 00028 in this spec sets `status='officialized'` explicitly in the RPC insert; the existing on_fine_status_change trigger handles the user_action emission.

**`is_group_admin` source-of-truth check** (canonical: `roles` JSONB array, post-00027): admin == founder in V1 (`create_group_with_admin` creates the row with `role='admin'`, migration 00019 backfills `roles=['founder','member']`). No multi-admin support yet; "Member management P1 #6" is the future spec that adds non-founder admins.

**`GovernanceAction` codegen exclusion** (scripts/codegen/README.md:37): explicitly out of codegen scope — adding a Swift case does not require TS regeneration.

## §1 — Architecture

```
ios/Tandas/
  Features/Fines/Sheets/AddManualFineSheet.swift           ← new View struct
  Features/Fines/Coordinator/AddManualFineCoordinator.swift ← new @Observable @MainActor
  Features/Events/Subviews/EventHostActionsSection.swift   ← edited (1 action card + 2 inputs)
  Features/Events/Views/EventDetailView.swift              ← edited (sheet state + canPerform task)
  Platform/Repositories/FineRepository.swift               ← edited (+1 protocol method, Mock + Live impl)
  Platform/Models/GovernanceAction.swift                   ← edited (+1 case)
  Platform/Models/GovernanceRules.swift                    ← edited (level(for:) switch +1 synthetic case)

supabase/migrations/
  00028_issue_manual_fine_officialize.sql         ← new (CREATE OR REPLACE RPC, status='officialized' explicit)
  00028_issue_manual_fine_officialize_rollback.sql ← new (CREATE OR REPLACE with prior body)

ios/TandasTests/Coordinator/AddManualFineCoordinatorTests.swift ← new
ios/TandasTests/Service/GovernanceServiceTests.swift            ← edited (+2 tests)
```

**Trigger flow**: EventDetailView → `EventHostActionsSection` adds `RuulActionableCard` "Multar manualmente" iff `governance.canPerform(.issueManualFine, member: me, in: group) == .allowed`. Tap sets `addManualFinePresented = true`; `.ruulSheet` presents `AddManualFineSheet`.

**Governance abstraction (CLAUDE.md compliance)**: View consults `GovernanceService.canPerform(.issueManualFine, ...)`, never `member.role == "admin"` directly. The synthetic `.founder` PermissionLevel inside `GovernanceRules.level(for:)` is the V1 implementation; if V2 needs configurability, a `whoCanIssueManualFine` field is added to `GovernanceRules` struct + `governance` jsonb defaults migration — view code unchanged.

**Sheet lives in Features/Fines/, not Features/Events/**: the entity is the fine; the event is contextual data passed by the caller. Mirrors how `AppealFineSheet` lives under Features/Fines/.

## §2 — Components

**1. `AddManualFineSheet` (View struct)** — `Features/Fines/Sheets/AddManualFineSheet.swift`

Wraps `ModalSheetTemplate` (same pattern as `CancelEventSheet` / `CloseEventSheet`). Vertical layout:

```
┌──────────────────────────────────────────┐
│ Multar manualmente             [✕]       │   ModalSheetTemplate header
├──────────────────────────────────────────┤
│ ¿A QUIÉN?                                │   sectionLabel
│ ┌──────────────────────────────────┐     │
│ │ ⓐ  Ana López          ✓          │     │   tappable member rows, checkmark on selected
│ │ ⓑ  Bruno Vega                    │     │
│ │ ⓒ  Carlos Ruiz                   │     │
│ └──────────────────────────────────┘     │
│                                          │
│ MONTO                                    │
│ ┌────────────────────────────┐           │
│ │ $ 200                      │           │   RuulTextField .number keyboard
│ └────────────────────────────┘           │
│                                          │
│ MOTIVO                                   │
│ ┌────────────────────────────┐           │
│ │ Llegó tarde sin avisar     │           │   RuulTextField multiline
│ └────────────────────────────┘           │
├──────────────────────────────────────────┤
│ [error callout if coordinator.error]     │
│ [    Multar a Ana — $200         ]       │   primary CTA, disabled iff !canSubmit
└──────────────────────────────────────────┘
```

Inputs: `@Binding isPresented: Bool`, `event: Event`, `group: Group`, `coordinator: AddManualFineCoordinator`. View is dumb — only renders state + dispatches `coordinator.submit()`. Member row reuses the visual pattern from `GroupInfoSheet.memberRow` (avatar + name + admin badge), with selection state added.

**2. `AddManualFineCoordinator`** — `Features/Fines/Coordinator/AddManualFineCoordinator.swift`

```swift
@Observable @MainActor
final class AddManualFineCoordinator {
    private let fineRepo: FineRepository
    private let groupsRepo: GroupsRepository

    let groupId: UUID
    let eventId: UUID

    var members: [MemberWithProfile] = []
    var isLoadingMembers: Bool = true
    var selectedMemberId: UUID?
    var amountText: String = ""
    var reason: String = ""
    var isSubmitting: Bool = false
    var error: String?

    init(groupId: UUID, eventId: UUID, fineRepo: FineRepository, groupsRepo: GroupsRepository)

    var canSubmit: Bool { /* see §4 validation */ }
    var parsedAmount: Decimal? { /* parse amountText, locale-tolerant */ }

    func loadMembers(currentUserId: UUID) async
    func submit(currentUserId: UUID) async -> Fine?
}
```

`loadMembers` calls `groupsRepo.membersWithProfiles(of: groupId)`, filters out `currentUserId`, sorts founders-first then alphabetically.

`submit` calls `fineRepo.issueManual(...)` with `eventId: self.eventId`, returns the resulting `Fine` on success or nil on failure (and sets `error`).

**3. `FineRepository.issueManual(...)` (protocol + Mock + Live)**

```swift
public protocol FineRepository: Actor {
    // …existing methods…
    func issueManual(
        groupId: UUID,
        userId: UUID,
        amount: Decimal,
        reason: String,
        eventId: UUID?
    ) async throws -> Fine
}
```

**Live**: `client.rpc("issue_manual_fine", params: Params(...)).execute().value`. Params struct serializes to the 6 named params with `p_rule_id: nil`. Returns the row directly (RPC returns `public.fines`).

**Mock**: appends a `Fine` with `status: .officialized`, `autoGenerated: false`, `issuedBy: <test fallback>`, `eventId: provided`, `ruleId: nil`, `ruleSnapshot: nil`.

**4. `EventHostActionsSection` modification**

Adds 2 inputs:
```swift
let canIssueManualFine: Bool
let onIssueManualFine: () -> Void
```

After the "Cancelar evento" `RuulActionableCard`:
```swift
if canIssueManualFine {
    RuulActionableCard(
        icon: "exclamationmark.triangle",
        title: "Multar manualmente",
        subtitle: "Sin pasar por reglas automáticas.",
        action: onIssueManualFine
    )
}
```

**5. `EventDetailView` / coordinator wiring**

Adds:
```swift
@State private var addManualFinePresented = false
@State private var canIssueManualFine: Bool = false
```

In `.task`: evaluates `governance.canPerform(.issueManualFine, member: currentMember, in: group)` and stores the result. Below existing sheets:
```swift
.ruulSheet(isPresented: $addManualFinePresented) {
    AddManualFineSheet(
        isPresented: $addManualFinePresented,
        event: event,
        group: group,
        coordinator: AddManualFineCoordinator(
            groupId: event.groupId,
            eventId: event.id,
            fineRepo: app.fineRepo,
            groupsRepo: app.groupsRepo
        )
    )
}
```

EventDetailCoordinator does not change — the fine is officialized server-side and the next refresh picks it up. No automatic refresh on submit success in V1.

**6. `GovernanceAction.issueManualFine` + `GovernanceRules.level(for:)`**

```swift
// GovernanceAction.swift
case issueManualFine = "whoCanIssueManualFine"
```

```swift
// GovernanceRules.swift
public func level(for action: GovernanceAction) -> PermissionLevel {
    switch action {
    case .modifyRules:        return whoCanModifyRules
    case .inviteMembers:      return whoCanInviteMembers
    case .removeMembers:      return whoCanRemoveMembers
    case .closeEvents:        return whoCanCloseEvents
    case .createVotes:        return whoCanCreateVotes
    case .modifyGovernance:   return whoCanModifyGovernance
    case .issueManualFine:    return .founder    // synthetic V1; no jsonb field yet
    }
}
```

No change to `GovernanceRules` struct fields. No `governance` jsonb migration. Server-side `is_group_admin` already aligned with founder via 00019 backfill.

**7. Migration `00028_issue_manual_fine_officialize.sql` (+ rollback)**

Forward migration: `CREATE OR REPLACE FUNCTION public.issue_manual_fine(...)` with the only change being the INSERT statement explicitly setting `status = 'officialized'`. All validators, snapshot logic, and grants identical.

```sql
-- 00028 — issue_manual_fine sets status='officialized' explicitly
--
-- Manual fines were being inserted with column-default status='proposed', and
-- the on_fine_inserted trigger explicitly skips manual fines, so they sat
-- invisible forever. The on_fine_status_change trigger emits finePending
-- when status flips to 'officialized', so setting status explicitly closes
-- the cycle.

create or replace function public.issue_manual_fine(
  p_group_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_reason text,
  p_rule_id uuid,
  p_event_id uuid
)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  r public.rules;
  v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  if p_rule_id is not null then
    select * into r from public.rules where id = p_rule_id;
    if found then
      v_snapshot := jsonb_build_object('trigger', r.trigger, 'action', r.action, 'rule_title', r.title);
    end if;
  end if;

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, event_id,
    auto_generated, issued_by, rule_snapshot, status
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id,
    false, auth.uid(), v_snapshot, 'officialized'
  )
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated;
```

Rollback: same `CREATE OR REPLACE` with the prior body (no explicit status, falls through to default 'proposed').

## §3 — Data flow

**Sheet presentation**:

```
EventDetailView.onAppear → task {}
  ├── governance.canPerform(.issueManualFine, member: me, in: group)
  └── store result in @State canIssueManualFine

EventHostActionsSection
  └── if canIssueManualFine: RuulActionableCard "Multar manualmente" [tap]
      └── addManualFinePresented = true

.ruulSheet { AddManualFineSheet(coordinator: …) }
  └── .task { await coordinator.loadMembers(currentUserId: me.userId) }

AddManualFineCoordinator.loadMembers
  ├── groupsRepo.membersWithProfiles(of: groupId)
  ├── filter out currentUserId
  ├── sort founders-first, alphabetic
  └── isLoadingMembers = false
```

**Submit**:

```
AddManualFineSheet [tap "Multar a Ana — $200"]
  └── coordinator.submit(currentUserId: me.userId)
      ├── guard canSubmit
      ├── isSubmitting = true; error = nil
      ├── try fineRepo.issueManual(groupId, userId, parsedAmount, reason.trimmed, eventId)
      │   └── LiveFineRepository.rpc("issue_manual_fine", ...)
      │       ├── server: validators + insert(status='officialized')
      │       │   └── on_fine_status_change trigger → user_actions(finePending) for fined user
      │       └── returns Fine
      ├── on success:
      │   ├── isSubmitting = false; haptic .success; isPresented = false
      └── on failure:
          ├── isSubmitting = false; error = humanizeError(...)
```

**Visibility for fined user (other session)**:

`finePending` user_action emitted by trigger → ActionInboxView shows the action; MyFinesView lists the fine with status `officialized`.

**Same-admin refresh**: not auto-refreshed in V1. Admin sees the fine after pull-to-refresh on the event or on next coordinator load. If real-world feedback shows this as broken, add an `onSubmit` callback in the sheet that triggers `parentCoordinator.refresh()` — low cost.

## §4 — Error handling and validation

**Client validation** (gates CTA enabled state):

| Field | Rule | UX |
|---|---|---|
| Member | `selectedMemberId != nil` | CTA disabled until set |
| Amount | `parsedAmount != nil && parsedAmount! >= 0` | CTA disabled; no inline red message |
| Reason | `reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2` | CTA disabled |
| Submit lock | `!isSubmitting` | CTA disabled; label changes to `"Multando…"` with inline spinner |

CTA label: `"Multar a \(memberName) — \(amountFormatted)"` when fully valid; falls back to `"Multar"` otherwise.

**Server error mapping** (`humanizeError(_:) -> String` inside the coordinator):

| Server raise | UI message |
|---|---|
| `auth required` | `"Tu sesión expiró. Volvé a entrar."` |
| `admin only` | `"Solo admins pueden multar manualmente."` |
| `target user not a member` | `"Esa persona ya no es miembro del grupo."` |
| `amount must be non-negative` | `"El monto no puede ser negativo."` |
| `reason required` | `"Escribe un motivo (al menos 2 caracteres)."` |
| network / timeout / decode | `"No pudimos enviar la multa. Intenta de nuevo."` |

Error displayed in a single `RuulCalloutCard.error` above the CTA — one error location per sheet, consistent with `AppealFineSheet`.

**Visual states**:

- Loading members (cold start): "¿A QUIÉN?" shows `LoadingStateView.compact`. CTA disabled.
- Empty members (group of 1): `EmptyStateView` "No hay otros miembros en este grupo." Amount/reason fields hidden, CTA invisible.
- Submitting: form fields disabled. CTA shows spinner.
- Error post-submit: form fields re-enabled, values preserved, error visible above CTA, CTA re-enabled for retry.
- Success: sheet closes, haptic success.

**Edge cases out of scope V1**:

- Duplicate fines (admin double-taps or creates two identical fines in seconds): no dedup. VoidFineSheet (next sprint) handles cleanup.
- Offline submit / queue: not implemented. Error shown, admin retries when online; form state preserved.
- Edit / undo after submit: not implemented. Modification only via `void_fine` (separate sprint).

## §5 — Testing

**Unit tests** (`Tests/AddManualFineCoordinatorTests.swift`, Swift Testing, mock-based):

- `loadMembers_excludesCurrentUser`
- `canSubmit_falseWhenNoMember`
- `canSubmit_falseWhenAmountInvalid`
- `canSubmit_falseWhenAmountNegative`
- `canSubmit_falseWhenReasonTooShort` (trimmed < 2 chars)
- `canSubmit_trueWhenAllValid`
- `submit_callsRepoWithCorrectParams` (groupId, userId, amount=200, reason, eventId)
- `submit_setsErrorOnRepoFailure`
- `submit_clearsErrorOnRetry`
- `submit_blocksDoubleTap` (second submit while in-flight is no-op)

**`GovernanceServiceTests.swift`** — add:

- `canPerform_issueManualFine_allowedForFounder` (roles=[.founder, .member]) → `.allowed`
- `canPerform_issueManualFine_deniedForMember` (roles=[.member]) → `.denied(notFounder)`

**Integration tests (deno, local-only via `supabase start`, CI deferred per Roadmap Fase 0 #2)**: optional this sprint. If included, `Tests/Edge/issue_manual_fine_test.ts`:

- Happy path: admin issues → row exists with `status='officialized'`, `auto_generated=false`, `issued_by=admin_uid`.
- Non-admin rejected.
- Target not member: rejected.
- Amount negative: rejected.
- Reason too short: rejected.

**Smoke manual (mandatory before merge)**:

1. Admin (founder) opens an event → CÓMO HOST visible → "Multar manualmente" visible.
2. Tap → sheet appears with members list (no admin in the list).
3. Select member → CTA changes to `"Multar a Ana — $0"`.
4. Fill amount + reason → CTA `"Multar a Ana — $200"` enabled.
5. Tap CTA → spinner → sheet closes → haptic success.
6. Switch to fined user (second device or logout/login): inbox shows `finePending` user_action; MyFinesView lists the fine with status `officialized`.
7. Regular member opens the same event → does NOT see "Multar manualmente" in CÓMO HOST (canPerform gate).
8. Group of 1 (admin only) → sheet shows empty state, CTA invisible.

**Build gate** (must succeed before commit):

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Must print `BUILD SUCCEEDED`.

**Migration gate**: `supabase/migrations/00028_issue_manual_fine_officialize.sql` applies cleanly on local (`supabase db reset`); rollback applies cleanly. Both files in commit.

## DoD

- [ ] Migration 00028 + rollback applied locally clean.
- [ ] `GovernanceAction.issueManualFine` case + `GovernanceRules.level(for:)` synthesis added.
- [ ] `FineRepository.issueManual` protocol method + Mock + Live impl.
- [ ] `AddManualFineCoordinator` with all unit tests passing.
- [ ] `AddManualFineSheet` rendering all visual states (loading, empty, idle, submitting, error).
- [ ] `EventHostActionsSection` action card behind canPerform gate.
- [ ] `EventDetailView` wires sheet presentation + canPerform task.
- [ ] `GovernanceServiceTests` +2 cases passing.
- [ ] `xcodebuild build` green for `generic/platform=iOS`.
- [ ] Smoke manual on real device covers all 8 scenarios.
- [ ] Roadmap Fase 0 #5 updated to mark AddManualFineSheet ✅.

## Follow-ups (registered, not blocking)

- VoidFineSheet (next sprint): own brainstorm covering "razón obligatoria u opcional", "voidear pagadas", "fineVoided system event", "reversibilidad", "notificación al multado".
- Auto-refresh post-submit if real-world feedback flags absence as bug.
- V2: `whoCanIssueManualFine` field in `GovernanceRules` struct + `governance` jsonb defaults migration if user-configurable becomes desired.
- V2: cross-event entry (FineDetailView "issue similar", ProfileView, GroupInfoSheet) once member-management lands.
