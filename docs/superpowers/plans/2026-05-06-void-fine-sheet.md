# VoidFineSheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin (V1: founder) annul a fine from `FineDetailView` — duplicates, manual errors, out-of-app resolutions — with the fined user notified via `user_actions(fineVoided)` and the void recorded in `system_events`.

**Architecture:** Migration 00029 adds two server guards (status whitelist + reason length) and two emissions (`user_action(fineVoided)` + `system_event(fineVoided)`) to the existing `void_fine` RPC. Swift gets a new `GovernanceAction.voidFine` (synthetic `.founder` level), a new `SystemEventType.fineVoided` (codegen-managed), a new `VoidFineSheet` + `VoidFineCoordinator` mirroring the AddManualFineSheet pattern. `FineDetailView` gains a destructive "Anular multa" button (admin-only) and an "ANULADA POR ADMIN" section. The post-void refresh story uses `VoidFineCoordinator.onSubmitted` — `MainTabView.fineDetailScreen`'s factory threads `coord.refresh` so the parent repaints before the sheet dismisses.

**Tech Stack:** SwiftUI iOS 26, Swift 6 strict concurrency, supabase-swift SDK, XCTest, PostgreSQL/PL/pgSQL (via Supabase), xcodegen + xcodebuild, lefthook pre-commit, `make gen` codegen.

**Spec reference:** `docs/superpowers/specs/2026-05-06-void-fine-sheet-design.md` (commits `ecc6902` + `64a2f03`).

---

## File Structure

**New files:**

- `supabase/migrations/00029_void_fine_guards_and_emit.sql` — single `CREATE OR REPLACE FUNCTION public.void_fine` with status guard, reason guard, and the two emissions.
- `supabase/migrations/00029_void_fine_guards_and_emit_rollback.sql` — restores the 00016 body verbatim (no guards, no emissions).
- `ios/Tandas/Features/Fines/Sheets/VoidFineSheet.swift` — modal sheet, dumb (renders coordinator state, dispatches `submit`).
- `ios/Tandas/Features/Fines/Coordinator/VoidFineCoordinator.swift` — `@Observable @MainActor` state holder. Resolves target name, validates reason, calls `fineRepo.void`, invokes `onSubmitted` on success.
- `ios/TandasTests/Fines/VoidFineCoordinatorTests.swift` — XCTest unit suite (~10 tests).

**Modified files:**

- `ios/Tandas/Platform/Models/GovernanceAction.swift` — +1 enum case `voidFine = "whoCanVoidFines"`.
- `ios/Tandas/Platform/Models/GovernanceRules.swift` — +1 case in `level(for:)` switch (synthetic `.founder`, no jsonb field).
- `ios/Tandas/Platform/Models/SystemEventType.swift` — +1 case `fineVoided` (codegen-managed; `make gen` regenerates `Generated/SystemEventType+Codable.swift`).
- `ios/Tandas/Platform/Models/SystemEventType+Extensions.swift` — add `.fineVoided` to the implemented-V1 set so it's `isImplementedInV1 == true`.
- `ios/Tandas/Platform/Repositories/FineRepository.swift` — `MockFineRepository` gains a `throwOnVoid` flag + `voidErrorMessage` setter. Live impl unchanged. Protocol surface unchanged.
- `ios/Tandas/Features/Fines/Views/FineDetailView.swift` — +3 inputs (`computeCanVoidFine`, `makeVoidFineCoordinator`, `currentUserId`), +2 `@State` (`voidSheetPresented`, `canVoidFine`), +1 `.task` for governance check, +1 `.ruulSheet`, restructured `actionFooter` to dispatch to `actionsForMyFine` or `actionsForAdmin`, new `voidedSection` body.
- `ios/Tandas/Features/Events/Views/MainTabView.swift` — `fineDetailScreen(_:)` constructs the closures using `app.governance`, `app.fineRepo`, `app.groupsRepo`, `app.session?.user.id`, `app.groups`, and threads `coord.refresh` via `onSubmitted`.
- `ios/TandasTests/Platform/GovernanceServiceTests.swift` — +2 tests (`testCanPerformVoidFine_allowedForFounder`, `testCanPerformVoidFine_deniedForNonFounder`).
- `Plans/Roadmap.md` — mark Fase 0 #4 VoidFineSheet ✅, tally → 4 of 5.

**Architectural note (locked):** `FineDetailView`'s signature gains 3 closures. The auto-refresh story is encapsulated in `VoidFineCoordinator.onSubmitted`, captured lexically in `makeVoidFineCoordinator`. `FineDetailCoordinator`'s API stays unchanged.

---

## Task 1: Migration 00029 — guards + emissions

**Files:**
- Create: `supabase/migrations/00029_void_fine_guards_and_emit.sql`
- Create: `supabase/migrations/00029_void_fine_guards_and_emit_rollback.sql`

- [ ] **Step 1: Write the forward migration**

Create `supabase/migrations/00029_void_fine_guards_and_emit.sql`:

```sql
-- 00029 — void_fine adds status guard, reason guard, and emits
--          user_action(fineVoided) + system_event(fineVoided).
--
-- Two latent gaps in the original 00016 void_fine RPC:
--
--   1. No status guard. Voiding a paid fine succeeded silently — the row
--      flipped to status='voided' but `paid=true` stayed, leaving an
--      inconsistent state. Refunds are out-of-scope here; if you want to
--      undo a paid fine, use a separate restitution flow.
--
--   2. No reason guard. The contract requires a human-readable motive for
--      audit + the fined user's notification body. Empty reason produced
--      a notification with empty body.
--
--   3. Zero emissions. The fined user got NO user_action and NO
--      system_event when their fine was voided. They'd just notice the
--      fine moved to "Resueltas" the next time they refreshed.
--
-- Fix:
--   - Reject status not in (proposed, officialized).
--   - Reject reason of length < 2 (after coalesce).
--   - Insert user_action(action_type='fineVoided', priority='normal') for
--     the fined user.
--   - Emit system_event(event_type='fineVoided') with payload
--     {amount, reason} for audit.

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
    jsonb_build_object(
      'amount', f.amount,
      'reason', p_reason,
      'voided_by_user_id', uid
    )
  );

  return f;
end;
$$;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.void_fine(uuid, text) to authenticated;
```

- [ ] **Step 2: Write the rollback migration**

Create `supabase/migrations/00029_void_fine_guards_and_emit_rollback.sql`:

```sql
-- 00029 rollback — restore 00016 void_fine body (no guards, no emissions).
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

  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;

  return f;
end;
$$;
revoke execute on function public.void_fine(uuid, text) from public, anon;
grant  execute on function public.void_fine(uuid, text) to authenticated;
```

- [ ] **Step 3: Commit migration files**

```bash
git add supabase/migrations/00029_void_fine_guards_and_emit.sql \
        supabase/migrations/00029_void_fine_guards_and_emit_rollback.sql
git commit -m "feat(db): 00029 void_fine adds status+reason guards and emits user_action+system_event"
```

Migration is applied to prod in Task 10, after the iOS code that depends on the new `fineVoided` action_type ships.

---

## Task 2: SystemEventType.fineVoided + codegen

**Files:**
- Modify: `ios/Tandas/Platform/Models/SystemEventType.swift:31-33`
- Modify: `ios/Tandas/Platform/Models/SystemEventType+Extensions.swift:7-13`
- Auto-regenerate: `ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift`

- [ ] **Step 1: Add the case**

Edit `ios/Tandas/Platform/Models/SystemEventType.swift`. Find the `// MARK: - Fines + appeals` section (line 30) and add `case fineVoided` right after `case fineOfficialized`:

```swift
    // MARK: - Fines + appeals
    case fineOfficialized
    case fineVoided
    case finePaid
    case fineReminderSent
    case appealCreated
    case appealResolved
    case voteOpened
    case voteCast
    case voteResolved
```

- [ ] **Step 2: Mark it implemented in V1**

Edit `ios/Tandas/Platform/Models/SystemEventType+Extensions.swift`. Add `.fineVoided` to the `isImplementedInV1` true-branch (line 12):

```swift
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved,
             .voteOpened, .voteCast, .voteResolved,
             .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
             .eventCreated, .memberJoined, .memberLeft:
            return true
```

- [ ] **Step 3: Regenerate codegen**

Run from repo root:
```bash
make gen
```

Expected: regenerates `ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift` with a `fineVoided` raw value `"fineVoided"` (matching the SQL emission in 00029).

Verify:
```bash
grep -n 'fineVoided' ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift
```
Expected: at least 2 matches (encode + decode).

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Platform/Models/SystemEventType.swift \
        ios/Tandas/Platform/Models/SystemEventType+Extensions.swift \
        ios/Tandas/Platform/Models/Generated/SystemEventType+Codable.swift
git commit -m "feat(models): SystemEventType.fineVoided + codegen"
```

(If lefthook regenerates the file inside the commit hook, the staged Generated file may differ — re-stage it and re-commit. lefthook does the right thing automatically.)

---

## Task 3: GovernanceAction.voidFine + GovernanceServiceTests

**Files:**
- Modify: `ios/Tandas/Platform/Models/GovernanceAction.swift:16-17`
- Modify: `ios/Tandas/Platform/Models/GovernanceRules.swift:76` (level switch)
- Modify: `ios/TandasTests/Platform/GovernanceServiceTests.swift` (append after existing tests)

- [ ] **Step 1: Write the failing tests**

Edit `ios/TandasTests/Platform/GovernanceServiceTests.swift`. Add two new test methods after `testCanPerformIssueManualFine_deniedForNonFounder` (line 44, before the closing brace of the class):

```swift
    // MARK: - .voidFine (V1: synthetic .founder level)

    func testCanPerformVoidFine_allowedForFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let founder = Member.mock(role: .founder, groupId: group.id)

        let decision = try await service.canPerform(
            .voidFine,
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

    func testCanPerformVoidFine_deniedForNonFounder() async throws {
        let service = GovernanceService()
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .member, groupId: group.id)

        let decision = try await service.canPerform(
            .voidFine,
            member: member,
            in: group,
            context: nil
        )

        guard case .denied(reason: .notFounder) = decision else {
            XCTFail("expected .denied(.notFounder), got \(decision)")
            return
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
    -scheme Tandas -project Tandas.xcodeproj \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:TandasTests/GovernanceServiceTests \
    2>&1 | grep -E "(error:|FAIL|PASS)" | head -20
```

Expected: compile error: `'voidFine' is not a member of 'GovernanceAction'`.

- [ ] **Step 3: Add the enum case**

Edit `ios/Tandas/Platform/Models/GovernanceAction.swift`. After line 16 (the `case issueManualFine` line) add:

```swift
    /// V1: synthetic `.founder` level inside `GovernanceRules.level(for:)`,
    /// no jsonb field. V2 may add `whoCanVoidFines` to `GovernanceRules`
    /// struct + governance jsonb defaults migration when user-configurable.
    case voidFine          = "whoCanVoidFines"
```

- [ ] **Step 4: Add the level branch**

Edit `ios/Tandas/Platform/Models/GovernanceRules.swift`. The `level(for:)` switch is at line 68. Find the `case .issueManualFine: return .founder` line (line 76) and add right below it:

```swift
        case .voidFine:           return .founder    // synthetic V1; no jsonb field yet
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
    -scheme Tandas -project Tandas.xcodeproj \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:TandasTests/GovernanceServiceTests \
    2>&1 | grep -E "(error:|Test Suite.*passed|Test Suite.*failed)" | head -10
```

Expected: 4 tests pass (`testCanPerformIssueManualFine_*` x2, `testCanPerformVoidFine_*` x2).

- [ ] **Step 6: Commit**

```bash
git add ios/Tandas/Platform/Models/GovernanceAction.swift \
        ios/Tandas/Platform/Models/GovernanceRules.swift \
        ios/TandasTests/Platform/GovernanceServiceTests.swift
git commit -m "feat(governance): .voidFine action with synthetic .founder level + tests"
```

---

## Task 4: MockFineRepository — void test hook

**Files:**
- Modify: `ios/Tandas/Platform/Repositories/FineRepository.swift:36-44` (var declarations + setter)
- Modify: `ios/Tandas/Platform/Repositories/FineRepository.swift:72-84` (void body)

- [ ] **Step 1: Add the throw flag and setters**

Edit `ios/Tandas/Platform/Repositories/FineRepository.swift`. The `MockFineRepository` declarations are at line 37-44. Add the new private fields and setters right after `setThrowOnIssueManual`:

```swift
public actor MockFineRepository: FineRepository {
    public private(set) var fines: [Fine] = []

    /// Test hook: when true, the next call to `issueManual` throws and resets.
    private var throwOnIssueManual: Bool = false

    public func setThrowOnIssueManual(_ value: Bool) { throwOnIssueManual = value }

    /// Test hook: when true, the next call to `void` throws and resets.
    private var throwOnVoid: Bool = false
    /// Test hook: error message for the next thrown void. Default mirrors a
    /// realistic server raise for humanize() coverage.
    private var voidErrorMessage: String = "only admins can void fines"

    public func setThrowOnVoid(_ value: Bool) { throwOnVoid = value }
    public func setVoidErrorMessage(_ message: String) { voidErrorMessage = message }

    public init(seed: [Fine] = []) { self.fines = seed }
```

- [ ] **Step 2: Honor the flag in `void`**

Replace the existing `void(fineId:reason:)` body at line 72 with:

```swift
    public func void(fineId: UUID, reason: String?) async throws -> Fine {
        if throwOnVoid {
            throwOnVoid = false
            throw NSError(
                domain: "MockFineRepository",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: voidErrorMessage]
            )
        }
        return try update(fineId: fineId) { f in
            Fine(
                id: f.id, groupId: f.groupId, userId: f.userId, ruleId: f.ruleId,
                eventId: f.eventId, reason: f.reason, amount: f.amount,
                status: .voided, paid: f.paid, paidAt: f.paidAt,
                waived: true, waivedAt: .now, waivedReason: reason,
                autoGenerated: f.autoGenerated, issuedBy: f.issuedBy,
                details: f.details, ruleSnapshot: f.ruleSnapshot,
                createdAt: f.createdAt, updatedAt: .now
            )
        }
    }
```

- [ ] **Step 3: Verify the project still compiles**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
    -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
    | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Platform/Repositories/FineRepository.swift
git commit -m "test(fines): MockFineRepository.void honors throwOnVoid flag"
```

---

## Task 5: VoidFineCoordinator — TDD

**Files:**
- Create: `ios/TandasTests/Fines/VoidFineCoordinatorTests.swift`
- Create: `ios/Tandas/Features/Fines/Coordinator/VoidFineCoordinator.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/TandasTests/Fines/VoidFineCoordinatorTests.swift`:

```swift
import Foundation
import XCTest
@testable import Tandas

@MainActor
final class VoidFineCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFine(
        id: UUID = UUID(),
        groupId: UUID = UUID(),
        userId: UUID = UUID(),
        amount: Decimal = 200,
        reason: String = "Llegó tarde sin avisar",
        status: FineStatus = .officialized
    ) -> Fine {
        Fine(
            id: id, groupId: groupId, userId: userId, ruleId: nil,
            eventId: nil, reason: reason, amount: amount,
            status: status, paid: false, paidAt: nil,
            waived: false, waivedAt: nil, waivedReason: nil,
            autoGenerated: false, issuedBy: UUID(),
            details: nil, ruleSnapshot: nil,
            createdAt: .now, updatedAt: .now
        )
    }

    private func makeMember(userId: UUID, groupId: UUID, displayName: String) -> MemberWithProfile {
        MemberWithProfile(
            member: Member(
                id: UUID(), groupId: groupId, userId: userId,
                role: "member", roles: [.member], joinedAt: .now
            ),
            profile: Profile(id: userId, displayName: displayName, phone: nil, createdAt: .now)
        )
    }

    private func makeMockGroupsRepo(seed: [MemberWithProfile]) -> MockGroupsRepository {
        MockGroupsRepository(membersWithProfilesSeed: seed)
    }

    // MARK: - resolveTargetName

    func test_resolveTargetName_setsNameFromGroup() async {
        let fine = makeFine()
        let target = makeMember(userId: fine.userId, groupId: fine.groupId, displayName: "Ana López")
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: MockFineRepository(seed: [fine]),
            groupsRepo: makeMockGroupsRepo(seed: [target])
        )

        await coord.resolveTargetName()

        XCTAssertEqual(coord.targetMemberName, "Ana López")
    }

    func test_resolveTargetName_fallsBackOnLookupFailure() async {
        let fine = makeFine()
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: MockFineRepository(seed: [fine]),
            groupsRepo: makeMockGroupsRepo(seed: [])  // empty — userId not present
        )

        await coord.resolveTargetName()

        XCTAssertEqual(coord.targetMemberName, "el multado")
    }

    // MARK: - canSubmit

    func test_canSubmit_falseWhenReasonEmpty() {
        let fine = makeFine()
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: MockFineRepository(seed: [fine]),
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = ""

        XCTAssertFalse(coord.canSubmit)
    }

    func test_canSubmit_falseWhenReasonTooShort() {
        let fine = makeFine()
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: MockFineRepository(seed: [fine]),
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = " a "  // trimmed = "a", count == 1

        XCTAssertFalse(coord.canSubmit)
    }

    func test_canSubmit_trueWhenReasonValid() {
        let fine = makeFine()
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: MockFineRepository(seed: [fine]),
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "Duplicada"

        XCTAssertTrue(coord.canSubmit)
    }

    // MARK: - submit

    func test_submit_callsRepoWithCorrectParamsAndReturnsVoidedFine() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "  Duplicada  "  // exercise trim

        let result = await coord.submit()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .voided)
        XCTAssertEqual(result?.waivedReason, "Duplicada")
        XCTAssertTrue(result?.waived ?? false)
    }

    func test_submit_setsErrorOnRepoFailure() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])
        await repo.setThrowOnVoid(true)
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "Duplicada"

        let result = await coord.submit()

        XCTAssertNil(result)
        XCTAssertNotNil(coord.error)
        XCTAssertTrue(coord.error?.contains("admin") ?? false)
    }

    func test_submit_clearsErrorOnRetry() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])
        await repo.setThrowOnVoid(true)
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "Duplicada"

        // First call fails, sets error.
        _ = await coord.submit()
        XCTAssertNotNil(coord.error)

        // Second call succeeds (throwOnVoid auto-resets after first throw).
        let result = await coord.submit()
        XCTAssertNotNil(result)
        XCTAssertNil(coord.error)
    }

    func test_submit_humanizesStatusGate() async {
        let fine = makeFine(status: .paid)
        let repo = MockFineRepository(seed: [fine])
        await repo.setThrowOnVoid(true)
        await repo.setVoidErrorMessage("cannot void fine with status paid")
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "Duplicada"

        _ = await coord.submit()

        XCTAssertNotNil(coord.error)
        XCTAssertTrue(coord.error?.contains("ya no se puede anular") ?? false)
    }

    func test_submit_blocksDoubleTap() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])
        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: [])
        )
        coord.reason = "Duplicada"

        // Fire two submits concurrently. First wins; second sees isSubmitting
        // and short-circuits via canSubmit.
        async let a = coord.submit()
        async let b = coord.submit()
        let (r1, r2) = await (a, b)

        // At least one should succeed; the second should return nil from the
        // canSubmit guard. Order is non-deterministic but exactly one fine
        // should exist with status .voided.
        XCTAssertTrue(r1 != nil || r2 != nil)
        XCTAssertFalse(r1 != nil && r2 != nil, "expected exactly one submit to win")
    }

    // MARK: - onSubmitted hook

    func test_submit_invokesOnSubmittedOnSuccess() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])

        actor Counter {
            var count = 0
            func inc() { count += 1 }
            func value() -> Int { count }
        }
        let counter = Counter()

        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: []),
            onSubmitted: { await counter.inc() }
        )
        coord.reason = "Duplicada"

        let result = await coord.submit()

        XCTAssertNotNil(result, "submit should succeed")
        let final = await counter.value()
        XCTAssertEqual(final, 1, "onSubmitted must run exactly once on success")
    }

    func test_submit_doesNotInvokeOnSubmittedOnFailure() async {
        let fine = makeFine()
        let repo = MockFineRepository(seed: [fine])
        await repo.setThrowOnVoid(true)

        actor Counter {
            var count = 0
            func inc() { count += 1 }
            func value() -> Int { count }
        }
        let counter = Counter()

        let coord = VoidFineCoordinator(
            fine: fine,
            fineRepo: repo,
            groupsRepo: makeMockGroupsRepo(seed: []),
            onSubmitted: { await counter.inc() }
        )
        coord.reason = "Duplicada"

        let result = await coord.submit()

        XCTAssertNil(result, "submit should fail")
        let final = await counter.value()
        XCTAssertEqual(final, 0, "onSubmitted must not run when submit fails")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
    -scheme Tandas -project Tandas.xcodeproj \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:TandasTests/VoidFineCoordinatorTests \
    2>&1 | grep -E "error:" | head -5
```

Expected: compile error: `cannot find 'VoidFineCoordinator' in scope` (and `MockGroupsRepository` if not yet importable — see fallback step below).

If `MockGroupsRepository` is not exported under `@testable`, the existing `AddManualFineCoordinatorTests.swift` already uses it — confirm the symbol is reachable; otherwise import it the same way that test does.

- [ ] **Step 3: Implement the coordinator**

Create `ios/Tandas/Features/Fines/Coordinator/VoidFineCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Coordinator backing `VoidFineSheet`. Resolves the target member's display
/// name, validates the reason, calls `FineRepository.void`, and humanizes
/// server errors. View is dumb: only renders this state and dispatches
/// `submit()`.
///
/// V1 entry: `FineDetailView` admin footer.
///
/// `onSubmitted` is the auto-refresh hook. It runs *before* `submit` returns
/// on success, so the parent `FineDetailCoordinator.refresh()` repaints
/// FineDetailView before the View dismisses the sheet — no flash of stale
/// state behind the closing sheet animation. Defaults to no-op so unit
/// tests don't have to wire it.
@Observable @MainActor
final class VoidFineCoordinator {
    let fine: Fine

    private(set) var targetMemberName: String = "el multado"
    var reason: String = ""
    private(set) var isSubmitting: Bool = false
    private(set) var error: String?

    private let fineRepo: any FineRepository
    private let groupsRepo: any GroupsRepository
    private let onSubmitted: () async -> Void
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.void")

    init(
        fine: Fine,
        fineRepo: any FineRepository,
        groupsRepo: any GroupsRepository,
        onSubmitted: @escaping () async -> Void = {}
    ) {
        self.fine = fine
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
        self.onSubmitted = onSubmitted
    }

    // MARK: - Derived state

    var canSubmit: Bool {
        guard !isSubmitting else { return false }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }

    // MARK: - Target name resolution

    /// Looks up the fined user's display name in the group. Falls back to
    /// "el multado" on any failure (logged warning, no UI error).
    func resolveTargetName() async {
        do {
            let rows = try await groupsRepo.membersWithProfiles(of: fine.groupId)
            if let mwp = rows.first(where: { $0.member.userId == fine.userId }) {
                targetMemberName = mwp.displayName
            }
        } catch {
            log.warning("resolveTargetName failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Submit

    /// Voids the fine via FineRepository. On success: calls `onSubmitted`
    /// (so the parent FineDetailCoordinator refreshes BEFORE the View
    /// dismisses the sheet) and returns the updated Fine. On failure: sets
    /// `error` via `humanize`, returns nil.
    @discardableResult
    func submit() async -> Fine? {
        guard canSubmit else { return nil }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let updated = try await fineRepo.void(fineId: fine.id, reason: trimmedReason)
            await onSubmitted()
            return updated
        } catch {
            self.error = humanize(error: error)
            return nil
        }
    }

    // MARK: - Error humanization

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("not authenticated") {
            return "Tu sesión expiró. Volvé a entrar."
        }
        if raw.contains("only admins") {
            return "Solo admins pueden anular multas."
        }
        if raw.contains("cannot void fine with status") {
            return "Esta multa ya no se puede anular (estado: \(fine.status.displayLabel))"
        }
        if raw.contains("reason required") {
            return "Escribe un motivo (al menos 2 caracteres)."
        }
        if raw.contains("fine not found") {
            return "Esta multa ya no existe."
        }
        return "No pudimos anular la multa. Intenta de nuevo."
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
    -scheme Tandas -project Tandas.xcodeproj \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:TandasTests/VoidFineCoordinatorTests \
    2>&1 | grep -E "(error:|Test Suite.*passed|Test Suite.*failed)" | head -10
```

Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tandas/Features/Fines/Coordinator/VoidFineCoordinator.swift \
        ios/TandasTests/Fines/VoidFineCoordinatorTests.swift
git commit -m "feat(fines): VoidFineCoordinator with onSubmitted refresh hook + 10 tests"
```

---

## Task 6: VoidFineSheet view

**Files:**
- Create: `ios/Tandas/Features/Fines/Sheets/VoidFineSheet.swift`

- [ ] **Step 1: Implement the sheet**

Create `ios/Tandas/Features/Fines/Sheets/VoidFineSheet.swift`:

```swift
import SwiftUI

/// Modal sheet for an admin to annul a fine. Caller is responsible for
/// dismissing the sheet on success — coordinator returns the voided Fine
/// and the View flips `isPresented = false` + fires haptic.
struct VoidFineSheet: View {
    @Binding var isPresented: Bool
    @Bindable var coordinator: VoidFineCoordinator

    var body: some View {
        ModalSheetTemplate(
            title: "Anular multa",
            dismissAction: { isPresented = false }
        ) {
            multaContextSection
            reasonSection
            if let error = coordinator.error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulSemanticError)
            }
            submitButton
        }
        .task {
            await coordinator.resolveTargetName()
        }
    }

    // MARK: - Read-only context card

    @ViewBuilder
    private var multaContextSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("MULTA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("\(coordinator.targetMemberName) — \(coordinator.fine.amountFormatted)")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("\u{201C}\(coordinator.fine.reason)\u{201D}")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.ruulBackgroundElevated,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Reason input

    @ViewBuilder
    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("MOTIVO DEL ANULADO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            RuulTextField(
                "Multa duplicada",
                text: $coordinator.reason
            )
            .disabled(coordinator.isSubmitting)
            Text("Visible para \(coordinator.targetMemberName).")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    // MARK: - Submit

    @ViewBuilder
    private var submitButton: some View {
        RuulButton(
            coordinator.isSubmitting ? "Anulando…" : "Anular multa",
            style: .destructive,
            size: .large,
            fillsWidth: true,
            isLoading: coordinator.isSubmitting
        ) {
            Task {
                if await coordinator.submit() != nil {
                    isPresented = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        }
        .disabled(!coordinator.canSubmit)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
    -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
    | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -5
```

Expected: `BUILD SUCCEEDED`. (If `RuulTextField`'s init signature differs from `init(_:text:)`, mirror what `AddManualFineSheet.swift` uses — open it as a reference and copy the constructor shape.)

- [ ] **Step 3: Commit**

```bash
git add ios/Tandas/Features/Fines/Sheets/VoidFineSheet.swift
git commit -m "feat(fines): VoidFineSheet — modal sheet with reason field + destructive CTA"
```

---

## Task 7: FineDetailView — Anular button + ANULADA section

**Files:**
- Modify: `ios/Tandas/Features/Fines/Views/FineDetailView.swift` (multiple sites)

- [ ] **Step 1: Add the new inputs and state**

Edit `ios/Tandas/Features/Fines/Views/FineDetailView.swift`. Replace the struct's leading declarations (lines 6-12) with:

```swift
struct FineDetailView: View {
    @Bindable var coordinator: FineDetailCoordinator
    var onAppeal: (() -> Void)?
    var onViewAppeal: ((Appeal) -> Void)?

    /// V1: gate for the "Anular multa" button. Resolved async on appear
    /// because governance.canPerform requires loading the user's Member row
    /// in the fine's group (cross-group fines via MyFinesView).
    let computeCanVoidFine: () async -> Bool
    /// Factory: creates a fresh `VoidFineCoordinator` each time the sheet
    /// is opened. Captures `app.governance`, repos, and `coord.refresh`
    /// (via onSubmitted) lexically in MainTabView.fineDetailScreen.
    let makeVoidFineCoordinator: () -> VoidFineCoordinator
    let currentUserId: UUID

    @State private var appealSheetPresented = false
    @State private var payConfirmPresented = false
    @State private var voidSheetPresented = false
    @State private var canVoidFine: Bool = false
```

- [ ] **Step 2: Add the governance task and the void sheet modifier**

In the `body` of `FineDetailView`, find the `.task { await coordinator.refresh() }` line (currently line 33) and the `.ruulSheet` block underneath. Replace the modifier chain with:

```swift
        .navigationTitle("Multa")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refresh() }
        .task { canVoidFine = await computeCanVoidFine() }
        .ruulSheet(isPresented: $appealSheetPresented) {
            AppealFineSheet(
                isPresented: $appealSheetPresented,
                fine: coordinator.fine
            ) { reason in
                Task { await coordinator.startAppeal(reason: reason) }
            }
        }
        .ruulSheet(isPresented: $voidSheetPresented) {
            // Fresh coordinator per open: makeVoidFineCoordinator() runs each
            // time the binding flips false→true. Deliberate — avoids leaking
            // partially-filled form state from cancelled sessions. The factory
            // wires onSubmitted = { coord.refresh() } so the parent repaints
            // before the sheet dismisses.
            VoidFineSheet(
                isPresented: $voidSheetPresented,
                coordinator: makeVoidFineCoordinator()
            )
        }
    }
```

- [ ] **Step 3: Add the voidedSection between evidenceSection and appealStatusInline**

In the body's outer `VStack`, currently:
```swift
                    hero
                    reasonCard
                    evidenceSection
                    appealStatusInline
```

Insert `voidedSection`:
```swift
                    hero
                    reasonCard
                    evidenceSection
                    voidedSection
                    appealStatusInline
```

Then add the `voidedSection` body below `evidenceSection`'s definition (search for `private var evidenceSection: some View` — insert after its closing brace):

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
                    .background(
                        Color.ruulBackgroundElevated,
                        in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                            .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
                    )
            }
        }
    }
```

- [ ] **Step 4: Add actionsForAdmin and dispatch from actionFooter**

The current `actionFooter` (line 184) is:
```swift
    @ViewBuilder
    private var actionFooter: some View {
        VStack {
            Spacer()
            if coordinator.isMine {
                actionsForMyFine
            }
        }
    }
```

Replace with:
```swift
    @ViewBuilder
    private var actionFooter: some View {
        VStack {
            Spacer()
            if coordinator.isMine {
                actionsForMyFine
            } else {
                actionsForAdmin
            }
        }
    }

    @ViewBuilder
    private var actionsForAdmin: some View {
        if canVoidFine,
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

- [ ] **Step 5: Verify build (will fail at the call site in MainTabView, fixed in Task 8)**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
    -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
    | grep -E "error:" | head -5
```

Expected: a single error referencing the missing `computeCanVoidFine`, `makeVoidFineCoordinator`, and `currentUserId` arguments at `MainTabView.fineDetailScreen` (`MainTabView.swift:225` area). This is the correct intermediate state — Task 8 fixes it.

- [ ] **Step 6: Commit**

```bash
git add ios/Tandas/Features/Fines/Views/FineDetailView.swift
git commit -m "feat(fines): FineDetailView Anular button + ANULADA section + 3 closures"
```

---

## Task 8: MainTabView wiring + auto-refresh

**Files:**
- Modify: `ios/Tandas/Features/Events/Views/MainTabView.swift:218-232` (the `fineDetailScreen` function)

- [ ] **Step 1: Replace fineDetailScreen body**

Edit `ios/Tandas/Features/Events/Views/MainTabView.swift`. The current `fineDetailScreen` function is at line 218:

```swift
    private func fineDetailScreen(_ fine: Fine) -> some View {
        let coord = FineDetailCoordinator(
            fine: fine,
            userId: app.session?.user.id ?? UUID(),
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo
        )
        return FineDetailView(
            coordinator: coord,
            onAppeal: nil,
            onViewAppeal: { appeal in
                voteOnAppealRoute = AppealRouteContext(appeal: appeal, fine: fine)
            }
        )
    }
```

Replace with:

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
                            id: UUID(),
                            groupId: fine.groupId,
                            userId: userId,
                            role: "member",
                            roles: [.member],
                            active: false,
                            joinedAt: .now
                        )
                    let decision = try await governance.canPerform(
                        .voidFine,
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
            makeVoidFineCoordinator: {
                // Captures `coord` lexically — when void succeeds, onSubmitted
                // refreshes FineDetailCoordinator so the View re-renders the new
                // state (status pill, hidden buttons, ANULADA section) before
                // the sheet closes.
                VoidFineCoordinator(
                    fine: fine,
                    fineRepo: fineRepo,
                    groupsRepo: groupsRepo,
                    onSubmitted: { await coord.refresh() }
                )
            },
            currentUserId: userId
        )
    }
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
    -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
    | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -5
```

Expected: `BUILD SUCCEEDED`.

If a compile error references `app.groups` or `app.governance`, those properties' exact names live on `AppState`. Open `ios/Tandas/AppState.swift` (or wherever `app` is typed) and copy the actual property name; the AddManualFineSheet wiring at `MainTabView.swift:411` is the canonical reference.

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/jj/code/tandas/ios && xcodebuild test \
    -scheme Tandas -project Tandas.xcodeproj \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    2>&1 | grep -E "(Test Suite.*(passed|failed))" | tail -5
```

Expected: all suites pass.

- [ ] **Step 4: Commit**

```bash
git add ios/Tandas/Features/Events/Views/MainTabView.swift
git commit -m "feat(fines): MainTabView wires VoidFineSheet closures with auto-refresh"
```

---

## Task 9: Smoke manual

This task is interactive. You run the app on simulator and verify the UI behaves per spec §5 smoke list.

**Files:** none (manual verification only).

- [ ] **Step 1: Boot the simulator**

```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1
open Tandas.xcodeproj
# In Xcode: select "iPhone 16" simulator, Cmd+R to run.
```

- [ ] **Step 2: Authenticate as the admin (jmizrahit@gmail.com → user 407d4283-…)**

OTP login via the app's auth screen. Confirm you land on the home with at least one group.

- [ ] **Step 3: Open one of the test group's fines**

Navigate to MyFines (if any) OR open the Cuates Test group → Fines tab → tap the Diego no-show fine ($150) seeded earlier.

- [ ] **Step 4: Verify visibility states (per spec §5 #1-#11)**

Walk through each scenario from the spec smoke list:

1. Admin opens **proposed** fine → "Anular multa" destructive button visible.
2. Tap → `VoidFineSheet` opens. MULTA card shows `[Name] — $[amount]` + original reason. Helper says `Visible para [Name].`
3. Empty reason → CTA disabled.
4. Single-char reason → CTA disabled.
5. Type "Duplicada" → CTA enabled.
6. Tap CTA → spinner → "Anulando…" → sheet closes → haptic. **No flash of stale state behind the closing sheet** (status pill must already say "ANULADA" before the sheet animation finishes).
7. FineDetailView final state → status dot tertiary, no Pagar/Apelar/Anular buttons, "ANULADA POR ADMIN" section with reason.
8. Switch to fined user (Diego) via a separate auth session: `ActionInboxView` shows "Multa anulada por admin: $150" with body "Duplicada". `MyFinesView` puts the fine in "Resueltas" tab with tertiary dot. Tap → ANULADA section visible.
9. Admin opens a **paid** fine → "Anular multa" NOT visible (status gate — gate hides the button before the server even sees the request).
10. Admin opens a **voided** fine → "Anular multa" NOT visible. ANULADA section visible.
11. Regular member (any non-founder test user) opens proposed/officialized fine → "Anular multa" NOT visible (canVoidFine gate returns false).

- [ ] **Step 5: Document smoke result**

If all 11 pass: proceed to Task 10. If any fail: STOP, document which step + actual behavior, and treat the fix as a follow-up task before continuing.

---

## Task 10: Apply migration 00029 to prod + final verify

This applies the migration to Supabase prod (project ref `fpfvlrwcskhgsjuhrjpz`). Same pattern as 00028 from earlier this session.

**Files:** none on disk; uses Supabase MCP.

**Prerequisites:** the executing session must already have the `mcp__supabase__apply_migration` and `mcp__supabase__execute_sql` tools loaded and the Supabase MCP authenticated. If not, run `/mcp` in the user's session first.

- [ ] **Step 1: Apply the forward migration to prod via MCP**

Read `supabase/migrations/00029_void_fine_guards_and_emit.sql` and apply it via:

```
mcp__supabase__apply_migration(
  name="00029_void_fine_guards_and_emit",
  query=<full file contents>
)
```

Expected: `{"success": true}`.

- [ ] **Step 2: Verify the function body has the new guards and emissions**

```
mcp__supabase__execute_sql(
  query="select prosrc from pg_proc where proname='void_fine';"
)
```

Expected: result body contains all five of:
- `cannot void fine with status`
- `reason required`
- `'fineVoided'` (twice — once in `user_actions` insert, once in `record_system_event`)
- `'Multa anulada por admin'`
- `'voided_by_user_id'` (the audit attribution key in the system_event payload)

- [ ] **Step 3: Smoke a void in prod**

Using the test data from earlier in this session:
- Fine `f0000000-0000-0000-0000-000000000001` (Diego's $150 no-show) is currently `officialized`.
- The 7 RLS-bypassing service-role insertion in this MCP session is fine — `auth.uid()` won't satisfy the admin check, so calling `void_fine` directly via MCP will fail. **Skip this.** The real smoke happens through the iOS app in Task 9.

If Task 9's smoke step 8 (fined user sees the user_action) passes, the prod migration is verified end-to-end.

- [ ] **Step 4: Confirm with the user**

State the migration is applied and ask for the green-light to mark the roadmap.

---

## Task 11: Roadmap update

**Files:**
- Modify: `Plans/Roadmap.md` (Fase 0 table)

- [ ] **Step 1: Find the Fase 0 P0 #4 entry**

```bash
grep -n "VoidFineSheet\|Fase 0\|P0 #4\|#4 " Plans/Roadmap.md | head -10
```

Identify the row for VoidFineSheet (P0 #4 in the spec's reference) and the running tally line (e.g. "3 of 5 shipped").

- [ ] **Step 2: Mark the row shipped and bump the tally**

Edit the row to flip whatever status indicator the file uses (e.g. 🟡 → ✅, or `[ ]` → `[x]`). Update the tally to "4 of 5".

If the file structure differs from the AddManualFineSheet update commit `451fbf5`, mirror that commit's diff style.

- [ ] **Step 3: Commit**

```bash
git add Plans/Roadmap.md
git commit -m "docs(roadmap): mark VoidFineSheet shipped (Fase 0 #4)"
```

- [ ] **Step 4: Push**

```bash
git push origin main 2>&1 | tail -3
```

Expected: branch advances cleanly to the merge commit list.

---

## Done

The shipping criteria from the spec's DoD are now all green:

- [x] Migration 00029 + rollback applied locally clean (Task 1).
- [x] `GovernanceAction.voidFine` + synthetic level + 2 tests (Task 3).
- [x] `SystemEventType.fineVoided` + codegen run (Task 2).
- [x] `VoidFineCoordinator` + 10 tests passing (Task 5).
- [x] `VoidFineSheet` rendering all visual states (Task 6).
- [x] `FineDetailView` renders Anular button + ANULADA section per status (Task 7).
- [x] `MainTabView.fineDetailScreen` wires closures (Task 8).
- [x] `xcodebuild build` green for `generic/platform=iOS` (Task 8 step 2).
- [x] Smoke manual covers all 11 scenarios (Task 9).
- [x] Migration applied to prod (`fpfvlrwcskhgsjuhrjpz`) via Supabase MCP (Task 10).
- [x] Roadmap Fase 0 #4 updated to mark VoidFineSheet ✅, tally → 4 of 5 (Task 11).
