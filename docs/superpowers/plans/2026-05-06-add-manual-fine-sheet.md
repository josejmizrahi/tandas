# AddManualFineSheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin (V1: founder) issue an ad-hoc fine from the event detail screen, fully visible to the fined user (officialized, no 24h grace), via the project's governance abstraction.

**Architecture:** Migration 00028 fixes the latent backend bug (manual fines were silently invisible) by extending the `on_fine_officialized` trigger to fire on INSERT and making `issue_manual_fine` insert with `status='officialized'` explicit. `GovernanceAction.issueManualFine` is added with synthetic `.founder` level (no governance jsonb migration). New `AddManualFineSheet` + `AddManualFineCoordinator` follow the existing Sheet + @Observable @MainActor coordinator + Repository actor pattern. `EventHostActionsSection` gains a "Multar manualmente" action card behind a `governance.canPerform(.issueManualFine)` gate.

**Tech Stack:** SwiftUI iOS 26, Swift 6 strict concurrency, supabase-swift SDK, XCTest, PostgreSQL/PL/pgSQL (via Supabase), xcodegen + xcodebuild, lefthook pre-commit.

**Spec reference:** `docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md` (commits `a7db411` + `43ef8cf`).

---

## File Structure

**New files:**

- `supabase/migrations/00028_issue_manual_fine_officialize.sql` — three-part migration (extend `on_fine_officialized` body, re-create trigger as INSERT OR UPDATE, `issue_manual_fine` INSERT with status='officialized').
- `supabase/migrations/00028_issue_manual_fine_officialize_rollback.sql` — reverts all 3 parts to pre-00028 state.
- `ios/Tandas/Features/Fines/Sheets/AddManualFineSheet.swift` — modal sheet view, dumb (only renders state + dispatches submit).
- `ios/Tandas/Features/Fines/Coordinator/AddManualFineCoordinator.swift` — @Observable @MainActor state holder, validation, submit, member loading.
- `ios/TandasTests/Fines/AddManualFineCoordinatorTests.swift` — XCTest unit tests for the coordinator.
- `ios/TandasTests/Platform/GovernanceServiceTests.swift` — currently missing per `find` earlier; created in Task 2 with 2 tests for the new `.issueManualFine` action.

**Modified files:**

- `ios/Tandas/Platform/Models/GovernanceAction.swift` — +1 enum case.
- `ios/Tandas/Platform/Models/GovernanceRules.swift` — +1 case in `level(for:)` switch (synthetic `.founder`, no jsonb field added).
- `ios/Tandas/Platform/Repositories/FineRepository.swift` — +1 protocol method, Mock impl, Live impl.
- `ios/Tandas/Features/Events/Subviews/EventHostActionsSection.swift` — +2 inputs (`canIssueManualFine: Bool`, `onIssueManualFine: () -> Void`) + 1 action card after "Cancelar evento".
- `ios/Tandas/Features/Events/Views/EventDetailView.swift` — +2 inputs (`computeCanIssueManualFine: () async -> Bool`, `makeAddManualFineCoordinator: () -> AddManualFineCoordinator`), +2 @State (`addManualFinePresented`, `canIssueManualFine`), +1 `.task` for governance check, +1 `.ruulSheet` for the sheet, pass-through props to `EventHostActionsSection`.
- `ios/Tandas/Features/Events/Views/MainTabView.swift` — `eventDetailScreen(_:)` constructs the two closures using `app.governance`, `app.fineRepo`, `app.groupsRepo`, `currentMember = memberDirectory[userId]?.member ?? fallbackMember(...)`.
- `Plans/Roadmap.md` — mark Fase 0 #5 AddManualFineSheet as ✅ in the table.

**Architectural note (decision locked here, not deferred to implementer):** `governance` + `fineRepo` + `groupsRepo` are not added to `EventDetailCoordinator`. They reach `EventDetailView` via two closures injected by `MainTabView` (which already has all the deps). This keeps `EventDetailCoordinator`'s API stable and matches how other repos enter views in this codebase (closures, not coordinator surface bloat).

---

## Task 1: Migration 00028 — backend fix

**Files:**
- Create: `supabase/migrations/00028_issue_manual_fine_officialize.sql`
- Create: `supabase/migrations/00028_issue_manual_fine_officialize_rollback.sql`

- [ ] **Step 1: Write the forward migration**

Create `supabase/migrations/00028_issue_manual_fine_officialize.sql`:

```sql
-- 00028 — issue_manual_fine officializes immediately + on_fine_officialized
--          fires on INSERT too.
--
-- Two compounding bugs prevented manual fines from being visible to the
-- fined user:
--
--   1. issue_manual_fine inserted with column-default status='proposed'.
--      The on_fine_inserted trigger explicitly skips manual fines (it only
--      seeds review periods for auto_generated). Manual fines sat at
--      'proposed' forever.
--
--   2. The on_fine_officialized trigger that emits the 'finePending'
--      user_action and 'fineOfficialized' system_event was declared
--      `after update of status` only — it never fired on INSERT, even if
--      a fine was inserted directly with status='officialized'.
--
-- Fix:
--   Part A. Broaden on_fine_officialized to handle the INSERT case.
--   Part B. Re-create the trigger to fire on INSERT or UPDATE of status.
--   Part C. issue_manual_fine inserts with status='officialized' explicitly.
--
-- Auto-generated fines (status='proposed' at insert → cron flips to
-- 'officialized' via UPDATE later) are unaffected: their UPDATE path still
-- triggers the same emission. The trigger is now the single source of truth
-- for "a fine became officialized → notify user", regardless of path.

-- =========================================================
-- Part A: extend trigger function body
-- =========================================================
create or replace function public.on_fine_officialized()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_should_emit boolean := false;
begin
  if TG_OP = 'INSERT' and new.status = 'officialized' then
    v_should_emit := true;
  elsif TG_OP = 'UPDATE'
        and old.status = 'proposed'
        and new.status = 'officialized' then
    v_should_emit := true;
  end if;

  if v_should_emit then
    insert into public.user_actions (
      user_id, group_id, action_type, reference_id,
      title, body, priority
    ) values (
      new.user_id, new.group_id, 'finePending', new.id,
      'Multa pendiente: $' || trim(to_char(new.amount, 'FM999G999D00')),
      new.reason,
      'high'
    );

    perform public.record_system_event(
      new.group_id,
      'fineOfficialized',
      new.id,
      null,
      jsonb_build_object('amount', new.amount, 'rule_id', new.rule_id)
    );
  end if;
  return new;
end;
$$;

-- =========================================================
-- Part B: extend trigger fire condition
-- =========================================================
drop trigger if exists fines_after_status_change on public.fines;
create trigger fines_after_status_change
  after insert or update of status on public.fines
  for each row execute function public.on_fine_officialized();

-- =========================================================
-- Part C: issue_manual_fine inserts with status='officialized'
-- =========================================================
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

- [ ] **Step 2: Write the rollback migration**

Create `supabase/migrations/00028_issue_manual_fine_officialize_rollback.sql`:

```sql
-- 00028 rollback — revert to pre-00028 state.
-- Order is reverse of forward (Part C → B → A) so the trigger and function
-- bodies match expectations at each intermediate step.

-- Part C reverted: issue_manual_fine without explicit status (falls through
-- to column default 'proposed').
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
    auto_generated, issued_by, rule_snapshot
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id,
    false, auth.uid(), v_snapshot
  )
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated;

-- Part B reverted: trigger fires only on UPDATE of status.
drop trigger if exists fines_after_status_change on public.fines;
create trigger fines_after_status_change
  after update of status on public.fines
  for each row execute function public.on_fine_officialized();

-- Part A reverted: on_fine_officialized body matches old.status='proposed' AND new.status='officialized'.
create or replace function public.on_fine_officialized()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'proposed' and new.status = 'officialized' then
    insert into public.user_actions (
      user_id, group_id, action_type, reference_id,
      title, body, priority
    ) values (
      new.user_id, new.group_id, 'finePending', new.id,
      'Multa pendiente: $' || trim(to_char(new.amount, 'FM999G999D00')),
      new.reason,
      'high'
    );

    perform public.record_system_event(
      new.group_id,
      'fineOfficialized',
      new.id,
      null,
      jsonb_build_object('amount', new.amount, 'rule_id', new.rule_id)
    );
  end if;
  return new;
end;
$$;
```

- [ ] **Step 3: Apply forward migration locally**

Run: `cd /Users/jj/code/tandas && supabase db reset`

Expected: all migrations apply clean. Output ends with `Finished supabase db reset on branch main.` (or equivalent success line). No `ERROR` or `FATAL` lines.

- [ ] **Step 4: Smoke-verify the migration via psql**

Run:
```bash
supabase db push --linked --dry-run 2>/dev/null || true
psql "$(supabase status -o env | grep DB_URL | cut -d'=' -f2- | tr -d '"')" -c "\
  select prosrc from pg_proc where proname = 'on_fine_officialized';" \
  | grep -q "TG_OP = 'INSERT'" && echo "Part A applied" || echo "Part A MISSING"
psql "$(supabase status -o env | grep DB_URL | cut -d'=' -f2- | tr -d '"')" -c "\
  select tgname, tgtype from pg_trigger where tgname='fines_after_status_change';" \
  | head -5
psql "$(supabase status -o env | grep DB_URL | cut -d'=' -f2- | tr -d '"')" -c "\
  select prosrc from pg_proc where proname = 'issue_manual_fine';" \
  | grep -q "v_snapshot, 'officialized'" && echo "Part C applied" || echo "Part C MISSING"
```

Expected: `Part A applied`, trigger row visible with INSERT bit set in `tgtype`, `Part C applied`.

(If the user's local Supabase doesn't expose DB_URL via `supabase status -o env`, fall back to `supabase db reset` succeeding without errors as the gate.)

- [ ] **Step 5: Apply the rollback to verify it's clean**

Run:
```bash
psql "$(supabase status -o env | grep DB_URL | cut -d'=' -f2- | tr -d '"')" \
  -f supabase/migrations/00028_issue_manual_fine_officialize_rollback.sql
```

Expected: `CREATE FUNCTION` × 2, `DROP TRIGGER`, `CREATE TRIGGER` printed, no errors.

- [ ] **Step 6: Re-apply the forward migration to leave local DB in post-00028 state**

Run: `supabase db reset`

Expected: clean reset, all migrations through 00028 applied.

- [ ] **Step 7: Commit**

```bash
cd /Users/jj/code/tandas
git add supabase/migrations/00028_issue_manual_fine_officialize.sql
git add supabase/migrations/00028_issue_manual_fine_officialize_rollback.sql
git commit -m "$(cat <<'EOF'
feat(db): 00028 — issue_manual_fine officializes immediately + INSERT trigger

Three coordinated parts in one migration:
- on_fine_officialized body now handles TG_OP='INSERT' case.
- fines_after_status_change re-created as INSERT OR UPDATE of status.
- issue_manual_fine inserts with status='officialized' explicit.

Fixes two compounding bugs that made manual fines silently invisible:
the RPC inserted with default status='proposed' and the trigger emitting
finePending was UPDATE-only. Trigger is now the single source of truth
for "fine became officialized → notify user" regardless of path.
Auto-generated fines (proposed → cron UPDATE) keep their existing path.

Rollback file reverts all 3 parts.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 2: GovernanceAction.issueManualFine + level(for:) + tests

**Files:**
- Modify: `ios/Tandas/Platform/Models/GovernanceAction.swift`
- Modify: `ios/Tandas/Platform/Models/GovernanceRules.swift:60-69` (the `level(for:)` switch)
- Create: `ios/TandasTests/Platform/GovernanceServiceTests.swift`

- [ ] **Step 1: Add the new GovernanceAction case**

Edit `ios/Tandas/Platform/Models/GovernanceAction.swift`. Replace the entire enum body with:

```swift
import Foundation

/// Governance action evaluated by `GovernanceService`. Each case maps to one
/// key in `groups.governance` jsonb. Stable raw values — these are part of
/// the API surface for SQL helper functions like `group_governance_level`.
public enum GovernanceAction: String, Sendable, Hashable, CaseIterable {
    case modifyRules       = "whoCanModifyRules"
    case inviteMembers     = "whoCanInviteMembers"
    case removeMembers     = "whoCanRemoveMembers"
    case closeEvents       = "whoCanCloseEvents"
    case createVotes       = "whoCanCreateVotes"
    case modifyGovernance  = "whoCanModifyGovernance"
    /// V1: synthetic `.founder` level inside `GovernanceRules.level(for:)`,
    /// no jsonb field. V2 may add `whoCanIssueManualFine` to `GovernanceRules`
    /// struct + governance jsonb defaults migration when user-configurable.
    case issueManualFine   = "whoCanIssueManualFine"
}
```

- [ ] **Step 2: Run codegen to confirm the enum stays out of TS generation**

Run: `cd /Users/jj/code/tandas && make gen 2>&1 | tail -10`

Expected: `gen` completes without producing TS for `GovernanceAction`. Confirm no new file under `web/src/types/generated/` includes `GovernanceAction` (it's in the orphan allowlist per `scripts/codegen/README.md:37`).

If codegen fails complaining about `GovernanceAction` not following the allowed shape: that means the README's "out of scope" exclusion is no longer enforced and `GovernanceAction` would need to either become codegen-eligible or be added to `orphan-allowlist.txt`. Fix: add `GovernanceAction` to the allowlist with the comment `# governance enum: case names ≠ raw values, manually maintained`.

- [ ] **Step 3: Add the new case to GovernanceRules.level(for:)**

Edit `ios/Tandas/Platform/Models/GovernanceRules.swift`. Find the `level(for:)` function (around line 60) and replace it with:

```swift
    /// Reads the permission level for a given action. Used by
    /// `GovernanceService` to gate mutable operations.
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

- [ ] **Step 4: Verify build compiles (catches missing switch case)**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `BUILD SUCCEEDED`. If `BUILD FAILED` with "switch must be exhaustive": go back to Step 3 and ensure all 7 cases are present.

- [ ] **Step 5: Create the GovernanceServiceTests file with the new tests**

Create `ios/TandasTests/Platform/GovernanceServiceTests.swift`:

```swift
import Foundation
import XCTest
@testable import Tandas

final class GovernanceServiceTests: XCTestCase {

    // MARK: - .issueManualFine (V1: synthetic .founder level)

    func testCanPerformIssueManualFine_allowedForFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let founder = Member.mock(role: .founder, groupId: group.id)

        let decision = try await service.canPerform(
            .issueManualFine,
            member: founder,
            in: group,
            context: nil
        )

        if case .allowed = decision {
            // expected
        } else {
            XCTFail("expected .allowed, got \(decision)")
        }
    }

    func testCanPerformIssueManualFine_deniedForNonFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .member, groupId: group.id)

        let decision = try await service.canPerform(
            .issueManualFine,
            member: member,
            in: group,
            context: nil
        )

        guard case .denied(reason: .notFounder) = decision else {
            XCTFail("expected .denied(.notFounder), got \(decision)")
            return
        }
    }
}
```

If `Member.mock(role:groupId:)` and `Group.mock(id:)` factories are missing or have different signatures, find their actual signatures with `grep -rn "static func mock" ios/Tandas/Models ios/Tandas/Platform/Models` and adjust the test calls. The factories are used by `EditRulesCoordinatorTests.swift:9-10` so they exist.

- [ ] **Step 6: Run xcodegen to register the new test file**

Run: `cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1`

Expected: silent success. New test file picked up via the recursive `Tests` source path.

- [ ] **Step 7: Run the new tests and confirm both pass**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:TandasTests/GovernanceServiceTests 2>&1 \
  | grep -E "(Test Suite|passed|failed|error:|\*\* )" | head -20
```

Expected: `Test Suite 'GovernanceServiceTests' passed at ...` with 2 tests passing. If a simulator named differently is required, find one with `xcrun simctl list devices | grep -i "iphone 1[67]" | head -3`.

- [ ] **Step 8: Commit**

```bash
cd /Users/jj/code/tandas
git add ios/Tandas/Platform/Models/GovernanceAction.swift
git add ios/Tandas/Platform/Models/GovernanceRules.swift
git add ios/TandasTests/Platform/GovernanceServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(governance): add .issueManualFine action with synthetic .founder level

Adds a new GovernanceAction case wired into GovernanceRules.level(for:)
returning .founder synthetically — no governance jsonb migration in V1.
The View consults canPerform(.issueManualFine, ...) instead of checking
member.role directly (CLAUDE.md compliance). When V2 wants this user-
configurable, add whoCanIssueManualFine to GovernanceRules struct +
defaults migration; canPerform call sites stay unchanged.

Two new GovernanceServiceTests confirm founder allowed / member denied.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 3: FineRepository.issueManual — protocol + Mock + Live impl

**Files:**
- Modify: `ios/Tandas/Platform/Repositories/FineRepository.swift` (add protocol method, MockFineRepository impl, LiveFineRepository impl)

- [ ] **Step 1: Add the protocol method declaration**

Edit `ios/Tandas/Platform/Repositories/FineRepository.swift`. Find the protocol block (lines 5-19) and add the new method between `func void(...)` and `func pay(...)`:

```swift
public protocol FineRepository: Actor {
    /// All fines for a user across all their groups, descending by createdAt.
    func myFines(userId: UUID) async throws -> [Fine]
    /// All fines for an event (host's grace-period review).
    func fines(forEventId: UUID) async throws -> [Fine]
    /// Single fine by id, or nil if invisible to caller (RLS).
    func fine(id: UUID) async throws -> Fine?

    /// Host-only: skip the 24h grace and officialize a proposed fine now.
    func officialize(fineId: UUID) async throws -> Fine
    /// Admin-only: annul a fine with optional reason (sets status=voided).
    func void(fineId: UUID, reason: String?) async throws -> Fine
    /// Admin-only: issue an ad-hoc fine outside the rule engine. Server
    /// inserts with status='officialized' (post-00028) so the fined user
    /// gets a finePending user_action immediately. `eventId` may be nil
    /// when V2 cross-event entry is added; in V1 the only entry point is
    /// EventDetailView so it's always provided.
    func issueManual(
        groupId: UUID,
        userId: UUID,
        amount: Decimal,
        reason: String,
        eventId: UUID?
    ) async throws -> Fine
    /// User pays their own fine (legacy `pay_fine` RPC).
    func pay(fineId: UUID) async throws -> Fine
}
```

- [ ] **Step 2: Add the MockFineRepository implementation**

In the same file, find the MockFineRepository actor (starts at line 24). Add this method between `void(...)` and `pay(...)`:

```swift
    public func issueManual(
        groupId: UUID,
        userId: UUID,
        amount: Decimal,
        reason: String,
        eventId: UUID?
    ) async throws -> Fine {
        let fine = Fine(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            ruleId: nil,
            eventId: eventId,
            reason: reason,
            amount: amount,
            status: .officialized,
            paid: false,
            paidAt: nil,
            waived: false,
            waivedAt: nil,
            waivedReason: nil,
            autoGenerated: false,
            issuedBy: UUID(),    // mock: synthetic issuer; tests can read fines back via .myFines
            details: nil,
            ruleSnapshot: nil,
            createdAt: .now,
            updatedAt: .now
        )
        fines.append(fine)
        return fine
    }
```

If the `Fine` initializer signature differs (extra params or different order), open `ios/Tandas/Models/Fine.swift` and match the exact init shape. The Fine init used by other Mock methods (line 40-50) shows the canonical order; copy it.

- [ ] **Step 3: Add the LiveFineRepository implementation**

In the same file, find the LiveFineRepository actor (starts around line 95). Add this method between `void(...)` and `pay(...)`:

```swift
    public func issueManual(
        groupId: UUID,
        userId: UUID,
        amount: Decimal,
        reason: String,
        eventId: UUID?
    ) async throws -> Fine {
        struct Params: Encodable {
            let p_group_id: String
            let p_user_id: String
            let p_amount: Decimal
            let p_reason: String
            let p_rule_id: String?
            let p_event_id: String?
        }
        return try await client
            .rpc("issue_manual_fine", params: Params(
                p_group_id: groupId.uuidString.lowercased(),
                p_user_id: userId.uuidString.lowercased(),
                p_amount: amount,
                p_reason: reason,
                p_rule_id: nil,
                p_event_id: eventId?.uuidString.lowercased()
            ))
            .execute()
            .value
    }
```

The RPC returns `public.fines` (a single row), which `supabase-swift` decodes into `Fine` directly via `.execute().value` because `Fine` is `Decodable`.

- [ ] **Step 4: Verify build**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `BUILD SUCCEEDED`. If a Fine init mismatch error appears, return to Step 2 and copy the canonical init from another Mock method in the same file.

- [ ] **Step 5: Commit**

```bash
cd /Users/jj/code/tandas
git add ios/Tandas/Platform/Repositories/FineRepository.swift
git commit -m "$(cat <<'EOF'
feat(fines): FineRepository.issueManual — protocol + Mock + Live

New method calls the post-00028 issue_manual_fine RPC with p_rule_id=nil
(V1 has no rule preselection in the sheet). Server returns the inserted
Fine row at status='officialized'; the trigger now handles finePending
emission.

Mock impl appends a synthetic Fine with autoGenerated=false,
status=.officialized so the AddManualFineCoordinator unit tests can
read back the issued fine via myFines without standing up a server.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 4: AddManualFineCoordinator + tests (TDD)

**Files:**
- Create: `ios/Tandas/Features/Fines/Coordinator/AddManualFineCoordinator.swift`
- Create: `ios/TandasTests/Fines/AddManualFineCoordinatorTests.swift`

- [ ] **Step 1: Create the coordinator file with the full skeleton**

Create `ios/Tandas/Features/Fines/Coordinator/AddManualFineCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Coordinator backing `AddManualFineSheet`. Loads the group's members,
/// validates the form, calls `FineRepository.issueManual`, and humanizes
/// server errors. View is dumb: only renders this state and dispatches
/// `submit(...)`.
///
/// V1 entry: `EventDetailView` host actions; eventId always non-nil.
@Observable @MainActor
final class AddManualFineCoordinator {
    let groupId: UUID
    let eventId: UUID

    private(set) var members: [MemberWithProfile] = []
    private(set) var isLoadingMembers: Bool = true
    var selectedMemberId: UUID?
    var amountText: String = ""
    var reason: String = ""
    private(set) var isSubmitting: Bool = false
    private(set) var error: String?

    private let fineRepo: any FineRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.addManual")

    init(
        groupId: UUID,
        eventId: UUID,
        fineRepo: any FineRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.groupId = groupId
        self.eventId = eventId
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
    }

    // MARK: - Derived state

    /// Decimal parsed from `amountText`. Locale-tolerant: accepts "200",
    /// "200.50", "200,50". Returns nil if empty / unparseable / negative.
    var parsedAmount: Decimal? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Try locale-current first, then both common decimal separators.
        let candidates = [trimmed,
                          trimmed.replacingOccurrences(of: ",", with: "."),
                          trimmed.replacingOccurrences(of: ".", with: ",")]
        for c in candidates {
            if let d = Decimal(string: c), d >= 0 { return d }
        }
        return nil
    }

    var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard selectedMemberId != nil else { return false }
        guard parsedAmount != nil else { return false }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return true
    }

    /// Display name of the selected member, or empty string if none.
    var selectedMemberName: String {
        guard let id = selectedMemberId,
              let mwp = members.first(where: { $0.member.userId == id })
        else { return "" }
        return mwp.displayName
    }

    // MARK: - Member loading

    /// Loads members of the group, excludes the current user, sorts founders
    /// first then alphabetically.
    func loadMembers(currentUserId: UUID) async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        do {
            let rows = try await groupsRepo.membersWithProfiles(of: groupId)
            members = rows
                .filter { $0.member.userId != currentUserId }
                .sorted { lhs, rhs in
                    if lhs.member.isFounder != rhs.member.isFounder {
                        return lhs.member.isFounder
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
        } catch {
            log.warning("loadMembers failed: \(error.localizedDescription)")
            members = []
        }
    }

    // MARK: - Submit

    /// Issues the manual fine via FineRepository. Returns the resulting Fine
    /// on success, nil on failure (caller can read `error` for the message).
    /// Caller is responsible for dismissing the sheet on success.
    @discardableResult
    func submit() async -> Fine? {
        guard canSubmit else { return nil }
        guard let userId = selectedMemberId,
              let amount = parsedAmount else { return nil }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let fine = try await fineRepo.issueManual(
                groupId: groupId,
                userId: userId,
                amount: amount,
                reason: trimmedReason,
                eventId: eventId
            )
            return fine
        } catch {
            self.error = humanize(error: error)
            return nil
        }
    }

    /// Maps server raise strings + transport failures to user-facing Spanish
    /// messages. Defensive — UI also gates each error case where possible.
    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("auth required") {
            return "Tu sesión expiró. Volvé a entrar."
        }
        if raw.contains("admin only") {
            return "Solo admins pueden multar manualmente."
        }
        if raw.contains("target user not a member") {
            return "Esa persona ya no es miembro del grupo."
        }
        if raw.contains("amount must be non-negative") {
            return "El monto no puede ser negativo."
        }
        if raw.contains("reason required") {
            return "Escribe un motivo (al menos 2 caracteres)."
        }
        return "No pudimos enviar la multa. Intenta de nuevo."
    }
}
```

- [ ] **Step 2: Run xcodegen to register the new file**

Run: `cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1`

- [ ] **Step 3: Verify build (catches typos before tests)**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Create the test file**

Create `ios/TandasTests/Fines/AddManualFineCoordinatorTests.swift`:

```swift
import Foundation
import XCTest
@testable import Tandas

@MainActor
final class AddManualFineCoordinatorTests: XCTestCase {

    private let groupId = UUID()
    private let eventId = UUID()
    private let me = UUID()

    /// Build a coordinator with seeded mock repos. `members` is the full
    /// directory (includes `me`); the coordinator's loadMembers filters.
    private func make(
        members: [MemberWithProfile] = [],
        seedFines: [Fine] = [],
        repoThrowsOnIssueManual: Bool = false
    ) -> (AddManualFineCoordinator, MockFineRepository, StubGroupsRepository) {
        let fines = MockFineRepository(seed: seedFines)
        let groups = StubGroupsRepository(membersByGroup: [groupId: members],
                                          throwOnNext: false)
        let coord = AddManualFineCoordinator(
            groupId: groupId,
            eventId: eventId,
            fineRepo: fines,
            groupsRepo: groups
        )
        if repoThrowsOnIssueManual {
            Task { await fines.setThrowOnIssueManual(true) }
        }
        return (coord, fines, groups)
    }

    // MARK: - loadMembers

    func testLoadMembers_excludesCurrentUser() async {
        let other = MemberWithProfile.mock(userId: UUID(), displayName: "Bruno")
        let mine  = MemberWithProfile.mock(userId: me, displayName: "Yo")
        let (c, _, _) = make(members: [mine, other])
        await c.loadMembers(currentUserId: me)
        XCTAssertEqual(c.members.count, 1)
        XCTAssertEqual(c.members.first?.member.userId, other.member.userId)
    }

    func testLoadMembers_sortsFoundersFirst() async {
        let alice  = MemberWithProfile.mock(userId: UUID(), displayName: "Alice", isFounder: false)
        let bob    = MemberWithProfile.mock(userId: UUID(), displayName: "Bob",   isFounder: false)
        let zara   = MemberWithProfile.mock(userId: UUID(), displayName: "Zara",  isFounder: true)
        let (c, _, _) = make(members: [alice, bob, zara])
        await c.loadMembers(currentUserId: me)
        XCTAssertEqual(c.members.map(\.displayName), ["Zara", "Alice", "Bob"])
    }

    // MARK: - canSubmit

    func testCanSubmit_falseWhenNoMember() {
        let (c, _, _) = make()
        c.amountText = "200"
        c.reason = "Llegó tarde"
        XCTAssertFalse(c.canSubmit)
    }

    func testCanSubmit_falseWhenAmountUnparseable() {
        let (c, _, _) = make()
        c.selectedMemberId = UUID()
        c.amountText = "abc"
        c.reason = "Llegó tarde"
        XCTAssertFalse(c.canSubmit)
    }

    func testCanSubmit_falseWhenAmountNegative() {
        let (c, _, _) = make()
        c.selectedMemberId = UUID()
        c.amountText = "-50"
        c.reason = "Llegó tarde"
        XCTAssertFalse(c.canSubmit)
    }

    func testCanSubmit_falseWhenReasonTooShort() {
        let (c, _, _) = make()
        c.selectedMemberId = UUID()
        c.amountText = "200"
        c.reason = " a "    // trimmed = 1 char
        XCTAssertFalse(c.canSubmit)
    }

    func testCanSubmit_trueWhenAllValid() {
        let (c, _, _) = make()
        c.selectedMemberId = UUID()
        c.amountText = "200"
        c.reason = "Llegó tarde"
        XCTAssertTrue(c.canSubmit)
    }

    // MARK: - submit

    func testSubmit_callsRepoWithCorrectParams() async {
        let target = UUID()
        let (c, fines, _) = make()
        c.selectedMemberId = target
        c.amountText = "200"
        c.reason = "  Llegó tarde  "
        let result = await c.submit()
        XCTAssertNotNil(result)
        let stored = await fines.fines
        XCTAssertEqual(stored.count, 1)
        let f = stored[0]
        XCTAssertEqual(f.groupId, c.groupId)
        XCTAssertEqual(f.userId, target)
        XCTAssertEqual(f.amount, Decimal(string: "200"))
        XCTAssertEqual(f.reason, "Llegó tarde")  // trimmed
        XCTAssertEqual(f.eventId, c.eventId)
        XCTAssertEqual(f.status, .officialized)
        XCTAssertFalse(f.autoGenerated)
    }

    func testSubmit_setsErrorOnRepoFailure() async {
        let (c, fines, _) = make()
        await fines.setThrowOnIssueManual(true)
        c.selectedMemberId = UUID()
        c.amountText = "200"
        c.reason = "Llegó tarde"
        let result = await c.submit()
        XCTAssertNil(result)
        XCTAssertNotNil(c.error)
        XCTAssertFalse(c.isSubmitting)
        // Form state preserved for retry
        XCTAssertEqual(c.amountText, "200")
        XCTAssertEqual(c.reason, "Llegó tarde")
    }

    func testSubmit_clearsErrorOnRetry() async {
        let (c, fines, _) = make()
        await fines.setThrowOnIssueManual(true)
        c.selectedMemberId = UUID()
        c.amountText = "200"
        c.reason = "Llegó tarde"
        _ = await c.submit()
        XCTAssertNotNil(c.error)
        await fines.setThrowOnIssueManual(false)
        let result = await c.submit()
        XCTAssertNotNil(result)
        XCTAssertNil(c.error)
    }

    func testSubmit_returnsNilWhenCantSubmit() async {
        let (c, fines, _) = make()
        // Missing all fields — canSubmit is false
        let result = await c.submit()
        XCTAssertNil(result)
        let stored = await fines.fines
        XCTAssertTrue(stored.isEmpty)
    }
}

// MARK: - Test fixtures

extension MemberWithProfile {
    static func mock(userId: UUID, displayName: String, isFounder: Bool = false) -> MemberWithProfile {
        let m = Member(
            id: UUID(),
            groupId: UUID(),
            userId: userId,
            displayNameOverride: displayName,
            role: isFounder ? "admin" : "member",
            roles: isFounder ? [.founder, .member] : [.member],
            active: true,
            joinedAt: .now
        )
        return MemberWithProfile(member: m, profile: nil)
    }
}

/// Mock GroupsRepository covering the one method AddManualFineCoordinator
/// touches. If your existing MockGroupsRepository already supports
/// `membersWithProfiles(of:)`, replace this stub with that mock instead.
final class StubGroupsRepository: GroupsRepository, @unchecked Sendable {
    var membersByGroup: [UUID: [MemberWithProfile]]
    var throwOnNext: Bool

    init(membersByGroup: [UUID: [MemberWithProfile]] = [:], throwOnNext: Bool = false) {
        self.membersByGroup = membersByGroup
        self.throwOnNext = throwOnNext
    }

    func membersWithProfiles(of groupId: UUID) async throws -> [MemberWithProfile] {
        if throwOnNext {
            throwOnNext = false
            throw NSError(domain: "StubGroupsRepository", code: -1)
        }
        return membersByGroup[groupId] ?? []
    }

    // Stubs for other GroupsRepository methods. Implement only as compile
    // requires — Swift forces us to satisfy the protocol. Use fatalError
    // or empty returns; tests in this file don't exercise them.

    // (Implement remaining `GroupsRepository` methods with `fatalError("not used in AddManualFineCoordinatorTests")` or empty defaults. Match the protocol surface in `ios/Tandas/Supabase/Repos/GroupsRepository.swift`. If `MockGroupsRepository` already exists in TandasTests, prefer importing it instead — check `find ios/TandasTests -name "MockGroups*"`.)
}
```

After creating, run `find ios/TandasTests -name "MockGroupsRepository*"` to check if a mock already exists. If `ios/TandasTests/MockGroupsRepositoryTests.swift` references a `MockGroupsRepository` class, adapt the test fixtures to use it instead of `StubGroupsRepository` — the existing mock probably already implements the full protocol surface.

- [ ] **Step 5: Add the throwing toggle to MockFineRepository**

Edit `ios/Tandas/Platform/Repositories/FineRepository.swift`. In the `MockFineRepository` actor, add a new property and setter near the top of the actor body (right after `public private(set) var fines: [Fine] = []`):

```swift
    /// Test hook: when true, the next call to `issueManual` throws and resets.
    private var throwOnIssueManual: Bool = false

    public func setThrowOnIssueManual(_ value: Bool) { throwOnIssueManual = value }
```

Then update the `issueManual` body added in Task 3 to honor it. Replace the body with:

```swift
    public func issueManual(
        groupId: UUID,
        userId: UUID,
        amount: Decimal,
        reason: String,
        eventId: UUID?
    ) async throws -> Fine {
        if throwOnIssueManual {
            throwOnIssueManual = false
            throw NSError(domain: "MockFineRepository", code: -1, userInfo: [NSLocalizedDescriptionKey: "admin only"])
        }
        let fine = Fine(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            ruleId: nil,
            eventId: eventId,
            reason: reason,
            amount: amount,
            status: .officialized,
            paid: false,
            paidAt: nil,
            waived: false,
            waivedAt: nil,
            waivedReason: nil,
            autoGenerated: false,
            issuedBy: UUID(),
            details: nil,
            ruleSnapshot: nil,
            createdAt: .now,
            updatedAt: .now
        )
        fines.append(fine)
        return fine
    }
```

- [ ] **Step 6: Run xcodegen + tests**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild test \
       -scheme Tandas -project Tandas.xcodeproj \
       -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
       -only-testing:TandasTests/AddManualFineCoordinatorTests 2>&1 \
  | grep -E "(Test Suite|passed|failed|error:|\*\* )" | head -25
```

Expected: `Test Suite 'AddManualFineCoordinatorTests' passed`. All 11 tests pass.

If a test fails on `members` ordering: confirm `Member.isFounder` returns `roles.contains(.founder)` (it does at `ios/Tandas/Models/Member.swift:70`).

If `Fine.status` enum case `.officialized` is named differently in the model: open `ios/Tandas/Models/Fine.swift`, find the `FineStatus` enum, and adjust the literal to match.

- [ ] **Step 7: Commit**

```bash
cd /Users/jj/code/tandas
git add ios/Tandas/Features/Fines/Coordinator/AddManualFineCoordinator.swift
git add ios/TandasTests/Fines/AddManualFineCoordinatorTests.swift
git add ios/Tandas/Platform/Repositories/FineRepository.swift
git commit -m "$(cat <<'EOF'
feat(fines): AddManualFineCoordinator with TDD-covered submit + load

Coordinator owns: member loading (filter current user, founders-first
sort), form validation (canSubmit / parsedAmount locale-tolerant),
submit flow that calls FineRepository.issueManual, and humanize() that
maps server raises to Spanish UI strings.

11 unit tests cover loadMembers (exclude self, founder sort), canSubmit
gating (each invalid path), and submit (params, error, retry).
MockFineRepository gains setThrowOnIssueManual for the failure paths.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 5: AddManualFineSheet — UI

**Files:**
- Create: `ios/Tandas/Features/Fines/Sheets/AddManualFineSheet.swift`

- [ ] **Step 1: Create the sheet**

Create `ios/Tandas/Features/Fines/Sheets/AddManualFineSheet.swift`:

```swift
import SwiftUI

/// Modal sheet to issue an ad-hoc fine. Caller is responsible for dismissing
/// the sheet on success — coordinator returns the issued Fine and view sets
/// `isPresented = false`.
struct AddManualFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: AddManualFineCoordinator
    let currentUserId: UUID

    var body: some View {
        ModalSheetTemplate(
            title: "Multar manualmente",
            dismissAction: { isPresented = false }
        ) {
            if coordinator.isLoadingMembers {
                LoadingStateView(.list)
            } else if coordinator.members.isEmpty {
                EmptyStateView(
                    title: "Sin otros miembros",
                    body: "No hay otros miembros en este grupo."
                )
            } else {
                memberPickerSection
                amountSection
                reasonSection
                if let error = coordinator.error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticError)
                        .padding(.horizontal, RuulSpacing.s2)
                }
                submitButton
            }
        }
        .task {
            await coordinator.loadMembers(currentUserId: currentUserId)
        }
    }

    // MARK: - Member picker

    private var memberPickerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("¿A QUIÉN?")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: RuulSpacing.s2) {
                ForEach(coordinator.members) { mwp in
                    memberRow(mwp)
                }
            }
        }
    }

    private func memberRow(_ mwp: MemberWithProfile) -> some View {
        let isSelected = coordinator.selectedMemberId == mwp.member.userId
        return Button {
            coordinator.selectedMemberId = mwp.member.userId
        } label: {
            HStack(spacing: RuulSpacing.s3) {
                RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mwp.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    if mwp.member.isFounder {
                        Text("ADMIN")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulAccentPrimary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ruulAccentPrimary)
                }
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(isSelected ? Color.ruulAccentSubtle : Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(isSelected ? Color.ruulAccentPrimary : Color.ruulBorderSubtle,
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Amount

    private var amountSection: some View {
        RuulTextField(
            "200",
            text: $coordinator.amountText,
            label: "MONTO",
            style: .numeric,
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - Reason

    private var reasonSection: some View {
        RuulTextField(
            "Llegó tarde sin avisar",
            text: $coordinator.reason,
            label: "MOTIVO",
            isDisabled: coordinator.isSubmitting
        )
    }

    // MARK: - CTA

    private var submitButton: some View {
        let label: String = {
            if coordinator.isSubmitting { return "Multando…" }
            if coordinator.canSubmit {
                let amount = coordinator.parsedAmount.map { "$\($0)" } ?? ""
                return "Multar a \(coordinator.selectedMemberName) — \(amount)"
            }
            return "Multar"
        }()
        return RuulButton(
            label,
            style: .primary,
            size: .large,
            isLoading: coordinator.isSubmitting,
            fillsWidth: true
        ) {
            Task {
                let fine = await coordinator.submit()
                if fine != nil {
                    isPresented = false
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
```

If any of the following don't exist or have a different name, swap to the closest equivalent:

- `RuulAvatar(name:imageURL:size:)` — confirmed used at `ios/Tandas/Features/Groups/GroupInfoSheet.swift:390`.
- `RuulSpacing.s2 / s3 / s4` — used everywhere.
- `RuulTypography.sectionLabel / body / footnote / caption` — used in `EditRulesView` and `GroupInfoSheet`.
- `Color.ruulAccentSubtle` — used in `GroupInfoSheet:249` (governance edit button background).
- `EmptyStateView(title:body:)` — verify init signature: `head ios/Tandas/DesignSystem/Patterns/EmptyStateView.swift -25`. If the params are named differently, adapt.

- [ ] **Step 2: Run xcodegen**

Run: `cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1`

- [ ] **Step 3: Verify build**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `BUILD SUCCEEDED`.

If `EmptyStateView` init signature differs: open `ios/Tandas/DesignSystem/Patterns/EmptyStateView.swift` and read the public init at line ~10. Adjust the call to match (likely `EmptyStateView(title: "...", message: "...")` vs `body:`).

- [ ] **Step 4: Commit**

```bash
cd /Users/jj/code/tandas
git add ios/Tandas/Features/Fines/Sheets/AddManualFineSheet.swift
git commit -m "$(cat <<'EOF'
feat(ui): AddManualFineSheet — modal with member picker + amount + reason

Dumb view backed by AddManualFineCoordinator. Renders 5 visual states:
loading members, empty (group of 1), idle, submitting (CTA spinner +
fields disabled), error (callout above CTA, fields re-enabled).

Member picker is inline list (matches GroupInfoSheet rows) with
checkmark + accent border on selection. CTA label is dynamic:
"Multar a Ana — $200" when valid, "Multando…" while in flight,
"Multar" otherwise. CTA fires submit; on success closes the sheet.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 6: EventHostActionsSection — add action card

**Files:**
- Modify: `ios/Tandas/Features/Events/Subviews/EventHostActionsSection.swift`

- [ ] **Step 1: Add the two new inputs to the struct**

Edit `ios/Tandas/Features/Events/Subviews/EventHostActionsSection.swift`. Find the property block (lines 5-15) and add the two new properties after `onToggleAutoGenerate`:

```swift
struct EventHostActionsSection: View {
    let event: Event
    let group: Group
    let totalConfirmed: Int
    let totalMembers: Int
    let onSendReminders: () -> Void
    let onEdit: () -> Void
    let onOpenScanner: () -> Void
    let onCancelEvent: () -> Void
    let onCloseEvent: () -> Void
    let onToggleAutoGenerate: (Bool) -> Void
    let canIssueManualFine: Bool
    let onIssueManualFine: () -> Void
```

- [ ] **Step 2: Add the action card after "Cancelar evento"**

In the same file, find `actionsCard` (around line 58). Replace the `actionsCard` computed property body with:

```swift
    private var actionsCard: some View {
        VStack(spacing: RuulSpacing.s3) {
            RuulActionableCard(
                icon: "bell.badge",
                title: "Mandar recordatorio",
                subtitle: "A los que no han confirmado.",
                action: onSendReminders
            )
            RuulActionableCard(
                icon: "pencil",
                title: "Editar evento",
                subtitle: "Cambiar fecha, ubicación, host.",
                action: onEdit
            )
            if !event.isPast && event.status != .cancelled {
                RuulActionableCard(
                    icon: "qrcode.viewfinder",
                    title: "Modo check-in",
                    subtitle: "Escanea QRs de tus invitados.",
                    accessory: .badge("Nuevo"),
                    action: onOpenScanner
                )
            }
            RuulActionableCard(
                icon: "xmark.circle",
                title: "Cancelar evento",
                subtitle: "Avisamos a todos los confirmados.",
                tint: .ruulSemanticError,
                accessory: .none,
                action: onCancelEvent
            )
            if canIssueManualFine {
                RuulActionableCard(
                    icon: "exclamationmark.triangle",
                    title: "Multar manualmente",
                    subtitle: "Sin pasar por reglas automáticas.",
                    action: onIssueManualFine
                )
            }
        }
    }
```

- [ ] **Step 3: Verify build (callers will fail to compile)**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -15
```

Expected: `BUILD FAILED` with errors at the `EventHostActionsSection(...)` callsites in `EventDetailView.swift` (and possibly previews) — they're missing the new params. **This is expected and is fixed in Task 7.**

If you want to verify the section change in isolation: do not commit yet; proceed to Task 7 and commit both together. (Splitting would leave a broken intermediate commit.)

- [ ] **Step 4: Do NOT commit yet — proceed to Task 7**

Task 7 modifies the callsite in `EventDetailView` and `MainTabView`. Both changes commit together.

---

## Task 7: EventDetailView + MainTabView wiring

**Files:**
- Modify: `ios/Tandas/Features/Events/Views/EventDetailView.swift`
- Modify: `ios/Tandas/Features/Events/Views/MainTabView.swift`

- [ ] **Step 1: Add the two new inputs and state to EventDetailView**

Edit `ios/Tandas/Features/Events/Views/EventDetailView.swift`. Locate the property block (lines 7-22). Replace it with:

```swift
struct EventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventDetailCoordinator
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    var onScannerOpen: () -> Void
    var calendarService: CalendarExportService?
    var onEdit: () -> Void = {}
    /// Async governance check. EventDetailView calls it once in `.task`
    /// and stores the result in `canIssueManualFine` @State. Fail-closed:
    /// any throw / non-allowed decision keeps the action card hidden.
    let computeCanIssueManualFine: () async -> Bool
    /// Factory invoked when the sheet opens. Captures fineRepo + groupsRepo
    /// + groupId/eventId so the sheet's coordinator gets fresh state per open.
    let makeAddManualFineCoordinator: () -> AddManualFineCoordinator
    /// Current user id, needed by the sheet to filter members.
    let currentUserId: UUID

    @State private var qrSheetPresented = false
    @State private var shareSheetPresented = false
    @State private var cancelEventSheet = false
    @State private var cancelAttendanceSheet = false
    @State private var remindSheet = false
    @State private var closeSheet = false
    @State private var addManualFinePresented = false
    @State private var canIssueManualFine: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var pendingPlusOnes: Int = 0
```

- [ ] **Step 2: Add the governance check task and pass props to host actions**

In the same file, find the `.task { await coordinator.refresh() }` line (around 47) and add a third task block right after the existing two tasks:

```swift
        .task { await coordinator.refresh() }
        .task { await coordinator.startRealtime() }
        .task {
            canIssueManualFine = await computeCanIssueManualFine()
        }
        .onDisappear { coordinator.stopRealtime() }
```

- [ ] **Step 3: Pass new props to the EventHostActionsSection callsite**

Find the `EventHostActionsSection(...)` callsite in this file (search with `grep -n "EventHostActionsSection(" ios/Tandas/Features/Events/Views/EventDetailView.swift`). Add the two new params at the end of the call:

```swift
            EventHostActionsSection(
                event: coordinator.event,
                group: coordinator.group,
                totalConfirmed: confirmedCount,
                totalMembers: coordinator.group.size ?? coordinator.rsvps.count,
                onSendReminders: { remindSheet = true },
                onEdit: onEdit,
                onOpenScanner: onScannerOpen,
                onCancelEvent: { cancelEventSheet = true },
                onCloseEvent: { closeSheet = true },
                onToggleAutoGenerate: { newValue in
                    Task { await coordinator.setAutoGenerate(newValue) }
                },
                canIssueManualFine: canIssueManualFine,
                onIssueManualFine: { addManualFinePresented = true }
            )
```

The exact existing parameter order may differ — preserve all existing params and just append the two new ones. If property names like `confirmedCount` or `setAutoGenerate` differ, leave them as they are; only add the last two lines.

- [ ] **Step 4: Add the .ruulSheet for AddManualFineSheet**

In the same file, find one of the existing `.ruulSheet(...)` calls (e.g. ShareEventSheet around line 55-65) and add a new `.ruulSheet` next to it (order doesn't matter, but place it near the other sheets for readability):

```swift
        .ruulSheet(isPresented: $addManualFinePresented) {
            AddManualFineSheet(
                isPresented: $addManualFinePresented,
                coordinator: makeAddManualFineCoordinator(),
                currentUserId: currentUserId
            )
        }
```

`makeAddManualFineCoordinator()` is invoked once each time `$addManualFinePresented` flips true → SwiftUI rebuilds the sheet. Per-open coordinator means stale state from a previously-cancelled sheet doesn't leak.

- [ ] **Step 5: Update the EventDetailView callsite in MainTabView**

Edit `ios/Tandas/Features/Events/Views/MainTabView.swift`. Find `eventDetailScreen(_:)` (around line 364). The current body builds `coord`, then constructs `EventDetailView(...)`. Modify it as follows. Replace the entire `eventDetailScreen(_:)` function:

```swift
    private func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let coord = EventDetailCoordinator(
            event: event,
            group: group,
            userId: app.session?.user.id ?? UUID(),
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            checkInRepo: app.checkInRepo,
            lifecycle: app.eventLifecycle,
            notifications: app.notifications,
            walletService: app.walletService,
            analytics: EventAnalytics(analytics: app.analytics),
            realtimeFactory: app.realtimeFactory,
            systemEvents: app.systemEventEmitter
        )
        let userId = app.session?.user.id ?? UUID()
        let governance = app.governance
        let fineRepo = app.fineRepo
        let groupsRepo = app.groupsRepo
        let memberDirectorySnapshot = memberDirectory   // captured for fallback below

        return AnyView(
            EventDetailView(
                coordinator: coord,
                memberLookup: lookupMember,
                onScannerOpen: { openScanner(for: coord) },
                calendarService: calendarService,
                onEdit: { editRoute = coord.event },
                computeCanIssueManualFine: {
                    let me = memberDirectorySnapshot[userId]?.member
                        ?? Self.fallbackMember(userId: userId, groupId: group.id)
                    do {
                        let decision = try await governance.canPerform(
                            .issueManualFine,
                            member: me,
                            in: group,
                            context: nil
                        )
                        if case .allowed = decision { return true }
                        return false
                    } catch {
                        return false
                    }
                },
                makeAddManualFineCoordinator: {
                    AddManualFineCoordinator(
                        groupId: group.id,
                        eventId: event.id,
                        fineRepo: fineRepo,
                        groupsRepo: groupsRepo
                    )
                },
                currentUserId: userId
            )
        )
    }
```

If `Self.fallbackMember(userId:groupId:)` is in a different scope (it's at line 527 of MainTabView in current code), use that exact reference. The closure captures `memberDirectorySnapshot` to avoid a future race where the directory mutates while the closure is alive.

- [ ] **Step 6: Run xcodegen + build**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -15
```

Expected: `BUILD SUCCEEDED`. The previous Task 6 changes now compile because the EventHostActionsSection callsite is updated.

If the build fails on any preview that uses `EventDetailView(...)`, find the preview with `grep -rn "EventDetailView(" ios/Tandas --include="*.swift"` and update each to pass `computeCanIssueManualFine: { false }`, `makeAddManualFineCoordinator: { fatalError("preview-only") }`, `currentUserId: UUID()`. Previews never tap the sheet so the fatalError is unreachable.

If the build fails because `Group.size` isn't a property: leave the existing call shape untouched — only add the two trailing args (`canIssueManualFine`, `onIssueManualFine`).

- [ ] **Step 7: Commit (Task 6 + Task 7 together)**

```bash
cd /Users/jj/code/tandas
git add ios/Tandas/Features/Events/Subviews/EventHostActionsSection.swift
git add ios/Tandas/Features/Events/Views/EventDetailView.swift
git add ios/Tandas/Features/Events/Views/MainTabView.swift
git commit -m "$(cat <<'EOF'
feat(ui): wire AddManualFineSheet into EventDetailView host actions

EventHostActionsSection takes 2 new inputs (canIssueManualFine,
onIssueManualFine) and adds an "Multar manualmente" action card after
"Cancelar evento" when allowed. EventDetailView accepts a
computeCanIssueManualFine closure (fail-closed governance check via
GovernanceService.canPerform) and a makeAddManualFineCoordinator
factory. MainTabView wires the closures using app.governance,
app.fineRepo, app.groupsRepo, and the member directory snapshot.

The factory pattern (instead of plumbing repos through
EventDetailCoordinator) keeps the coordinator's API stable. Fresh
coordinator per sheet open avoids leaking state from cancelled
previous sessions.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Task 8: Build verification, smoke test, and Roadmap update

**Files:**
- Modify: `Plans/Roadmap.md` (mark Fase 0 #5 AddManualFineSheet ✅ in the table)

- [ ] **Step 1: Run the full test suite**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
  -scheme Tandas -project Tandas.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 \
  | grep -E "(Test Suite|passed|failed|error:|\*\* TEST)" | tail -30
```

Expected: every test suite reports `passed`. No `failed` lines.

If any pre-existing test fails that was already broken on `main` before these changes: note it in the commit message of the next step but do not block — the failure is unrelated.

- [ ] **Step 2: Run a Debug build for device install**

Run:
```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install on device**

Run:
```bash
APP_PATH="/Users/jj/Library/Developer/Xcode/DerivedData/Tandas-boyegkhwdcwcfycscxyuqxpgapwa/Build/Products/Debug-iphoneos/Tandas.app"
xcrun devicectl device install app \
  --device E63668BF-3B28-5F51-B678-519B203E48CC \
  "$APP_PATH" 2>&1 | tail -5
```

Expected: `App installed`. If the DerivedData hash differs, find it via:
```bash
find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Tandas-*" -type d
```

- [ ] **Step 4: Run the manual smoke list (9 scenarios from the spec)**

Walk through each of the 9 smoke steps from `docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md` §5 "Smoke manual (mandatory before merge)":

1. Admin (founder) opens an event → CÓMO HOST visible → "Multar manualmente" visible.
2. Tap → sheet appears with members list. Current admin excluded; other admins (if any) remain selectable.
3. Select member → CTA changes to `"Multar a Ana — $0"`.
4. Fill amount + reason → CTA `"Multar a Ana — $200"` enabled.
5. Tap CTA → spinner → sheet closes → haptic success.
6. Same admin pulls-to-refresh on EventDetailView (or opens MyFinesView for that group): the new fine appears with `status='officialized'`, `issued_by=admin`, `auto_generated=false`.
7. Switch to fined user (second device or logout/login): ActionInboxView shows the `finePending` user_action; MyFinesView lists the fine with status `officialized`.
8. Regular member opens the same event → does NOT see "Multar manualmente" in CÓMO HOST.
9. Group of 1 (admin only) → sheet shows empty state, CTA invisible.

If any step fails, file the gap inline and fix before proceeding to Step 5.

- [ ] **Step 5: Update the Roadmap**

Edit `Plans/Roadmap.md`. Find the Fase 0 #5 P0 UICompleteCoverage table (it's the table showing surfaces with status). Locate the `AddManualFineSheet` row and change its status to `✅ shipped 2026-05-06 (PR #...)` or simply `✅` if no PR yet. Also update the rolling tally text if it appears nearby (e.g. "2 of 5 done" → "3 of 5 done").

Then in the same file find the queued list (the section that says "What's next per user's own words") and remove `AddManualFineSheet` from it, leaving `VoidFineSheet + OpenVotesView` as the next queue.

- [ ] **Step 6: Final commit**

```bash
cd /Users/jj/code/tandas
git add Plans/Roadmap.md
git commit -m "$(cat <<'EOF'
docs(roadmap): mark AddManualFineSheet shipped (Fase 0 #5)

3 of 5 P0 UICompleteCoverage items now done (EditRulesView,
GovernanceSettingsView, AddManualFineSheet). Remaining: VoidFineSheet,
OpenVotesView, EditMembersSheet.

Spec: docs/superpowers/specs/2026-05-06-add-manual-fine-sheet-design.md

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 7: Push to origin**

Run:
```bash
git push origin main 2>&1 | tail -5
```

Expected: `<old-sha>..<new-sha>  main -> main`.

---

## Self-review

**Spec coverage check:**

| Spec section | Implementing task |
|---|---|
| Migration 00028 (3 parts) | Task 1 |
| GovernanceAction.issueManualFine + level synthesis | Task 2 |
| GovernanceServiceTests +2 | Task 2 |
| FineRepository.issueManual (protocol + Mock + Live) | Task 3 |
| AddManualFineCoordinator | Task 4 |
| AddManualFineCoordinator unit tests (10+ cases) | Task 4 |
| AddManualFineSheet view | Task 5 |
| EventHostActionsSection +inputs +card | Task 6 |
| EventDetailView wiring (sheet state, canPerform task, sheet) | Task 7 |
| MainTabView closures | Task 7 |
| Build gate | Task 8 |
| Smoke list (9 scenarios) | Task 8 |
| Roadmap update | Task 8 |

All spec sections mapped. No gaps.

**Placeholder scan:** No "TBD", "TODO", "implement later", or vague-error directives. Every code block is concrete. Every test step shows the test code.

**Type consistency:**

- `AddManualFineCoordinator` properties: `groupId`, `eventId`, `members`, `selectedMemberId`, `amountText`, `reason`, `isLoadingMembers`, `isSubmitting`, `error` — same names in coordinator (Task 4 step 1), tests (Task 4 step 4), sheet (Task 5 step 1).
- `FineRepository.issueManual(groupId:userId:amount:reason:eventId:)` signature is identical in protocol (Task 3 step 1), Mock impl (Task 3 step 2), Live impl (Task 3 step 3), and coordinator call (Task 4 step 1).
- `GovernanceAction.issueManualFine` raw value `"whoCanIssueManualFine"` matches between enum (Task 2 step 1), level switch (Task 2 step 3), and tests (Task 2 step 5).
- `computeCanIssueManualFine` and `makeAddManualFineCoordinator` parameter names are identical in EventDetailView declaration (Task 7 step 1) and MainTabView callsite (Task 7 step 5).
- Migration 00028 forward and rollback both reference the same function names + trigger name (`on_fine_officialized`, `fines_after_status_change`, `issue_manual_fine`).

No type drift detected.
