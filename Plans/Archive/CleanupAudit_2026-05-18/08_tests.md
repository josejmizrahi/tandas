# Ruul iOS Test Coverage Audit

All test code lives in `/Users/jj/code/tandas/ios/TandasTests/` + `/Users/jj/code/tandas/ios/TandasUITests/` + `/Users/jj/code/tandas/supabase/functions/_tests/`. **`Packages/RuulCore/Tests/` and `Packages/RuulFeatures/Tests/` do not exist** — there are zero SwiftPM-level unit tests; everything sits in the umbrella host app target.

## 1. Test inventory

| Area | Files | Tests | LOC |
|---|---:|---:|---:|
| Core (TandasTests/Platform, MockX, Models, RuulError, LoadPhase, Realtime) | 28 | ~145 | ~2,800 |
| Capabilities (TandasTests/Capabilities) | 9 | 73 | 1,403 |
| Features (TandasTests/Events, Fines, Rules, Votes, Notifications, Onboarding, Resources, Shell) | 28 | ~150 | ~3,000 |
| DesignSystem (TandasTests/DesignSystem) | 3 | 20 | 298 |
| UI (TandasUITests) | 1 | 0 (1 `XCTSkipIf`) | 28 |
| Edge functions (`_tests/db`) | 11 | 49 | 2,266 |
| Edge functions (`_tests/e2e`) | 17 | 47 | 3,160 |
| Edge functions (root whitelists + asset_rules + types) | 6 | 18 | 1,254 |
| **Total** | **103** | **~502** | **~14,200** |

## 2. Coverage map (doctrinal)

| Domain | Covered? | Where |
|---|---|---|
| Creation flow (Variant→Intent→LazyActivator) | YES (3 files, 18 @Test) | `TandasTests/Resources/{ResourceVariantRegistry,ResourceIntentRegistry,LazyCapabilityActivator}Tests.swift` |
| Resource detail capability hiding (capability not user-managed) | PARTIAL (only one assert at `CapabilityResolver+SecondaryActionsTests.swift:182`) | doctrine "auto-on, never user-visible" untested anywhere else |
| Atoms append-only | YES (edge DB) | `_tests/db/consistency_atom_infra.test.ts` (ledger_entries, system_events, vote_casts) |
| Projections recomputable | PARTIAL | `_tests/e2e/balanceProjection.test.ts` + `Platform/Resources/SpaceProjectionRepositoryTests.swift` (5 @Test) — no determinism/recompute test |
| Right state projection | PARTIAL | `_tests/db/consistency_right_doctrine.test.ts` (4 tests) + `Platform/MockRightRepositoryTests.swift` (5 tests). No iOS-side state derivation test |
| Fund lock projection | PARTIAL | `_tests/db/consistency_money.test.ts` (5) + `_tests/db/consistency_asset_lock.test.ts` (2). iOS side `FundRepositoryTests` covers `lock+unlock toggle` but not lock-event idempotency or projection drift |
| rule_evaluations idempotency | YES | `_tests/db/consistency_rule_evaluations.test.ts` (3 tests — UPSERT dedupe, UPDATE/DELETE reject, verdict CHECK) |
| Role/permission resolver | YES (iOS + DB) | `Platform/GovernanceServiceTests.swift` (8 XCTest) + `_tests/db/role_write_guards.test.ts` (9), `_tests/db/can_modify_rules.test.ts` (6) |
| Resource links | NO | `ResourceLinkRepository` and `MockResourceLinkRepository` exist; **zero @Test references** |
| Booking vs waitlist consent | PARTIAL | `SpaceLifecycleRepositoryTests` covers happy path (`joinWaitlist`, `promoteFromWaitlist`). **No test asserting consent gate / opt-in when promoting** |

## 3. Tests testing dead behavior

- `TandasUITests/HappyPathTests.swift:25` — `testFullOnboardingThroughCreatingGroup` is permanently `XCTSkipIf(true)`. The entire `TandasUITests` target ships zero executable tests.
- `TandasTests/Votes/OpenVotesCoordinatorTests.swift:63-78` — `sectioned()` `.disabled("Pre-existing stale test")`, tracked as orphan post-Beta 1.
- `TandasTests/Capabilities/CapabilityResolver+SecondaryActionsTests.swift:170-183` — name says `"no archive or enableCapability"` but it’s now a guard ASSERTING the deletion (`#expect(!kinds.contains(.enableCapability))`). Correct doctrinally, but the title is misleading.

## 4. Orphan references to deleted types

- `GovernanceTabView`, `ManageCapabilitiesSheet`, `AdvancedCapabilitiesView`, `EditCapabilityConfigSheet`, `SettingsSectionView` — **zero references in TandasTests/TandasUITests**. No orphan compile risk.

## 5. Duplicate / fragile tests

- **CapabilityResolver split across 5 files** with overlapping intent: `Capabilities/CapabilityResolver+{Right,SecondaryActions,PrimaryAction}Tests.swift` + `Capabilities/CapabilityResolverExpandedTests.swift` + `Platform/CapabilityResolverTests.swift`. Platform/CapabilityResolverTests (149 LOC, 10 @Test, last touched 2026-05-11) is the oldest and partially supplanted by the newer `Capabilities/` suite — candidate for merge or deletion.
- `MockGroupsRepositoryTests` cascade tests (lines 132-198) overlap with edge-tested cascade in `_tests/db/can_modify_rules.test.ts` + module cascade lives both client + server.
- `MockRightRepositoryTests` (5 @Test) duplicates argument-recording assertions that `CapabilityResolver+RightTests` already exercises end-to-end.

## 6. Mocks duplication (inline instead of shared `Mock*Repository`)

- `TandasTests/Fines/AddManualFineCoordinatorTests.swift:173-279` — entire `StubGroupsRepository` actor (107 LOC, 22 `fatalError("not used")`) reimplements `GroupsRepository` despite `MockGroupsRepository` shipping with the seed of `membersWithProfilesSeed:` (RuulCore Repositories/GroupsRepository.swift:126). Pure duplication.
- `TandasTests/Notifications/SignOutRevokesTokenTests.swift:68` — `ThrowingTokenRepo` actor inline; no shared `MockNotificationTokenRepository` exists yet (gap to add to Repositories).
- `TandasTests/Notifications/SendHostRemindersTests.swift:142,151` — two private actors (`RateLimitedFakeDispatcher`, `ThrowingFakeDispatcher`); no shared dispatcher mock.
- `TandasTests/Rules/EditRulesCoordinatorTests.swift:79` — `MockGovernanceService` defined inline as `final class … @unchecked Sendable`; `GovernanceServiceProtocol` has no shared mock implementation.

## 7. Doctrinal tests missing (prioritized)

1. **Resource detail capability hiding** — `CapabilityToggleNotPresentInUITests.testNoToggleSurfacedAnywhere()` (snapshot or view introspection that no `Toggle`/`Button` with capability id is rendered).
2. **Resource links** — `ResourceLinkRepositoryTests.testMockLifecycle()` + edge test for FK + cascade.
3. **Booking↔waitlist consent** — `SpaceLifecycleRepositoryTests.testPromoteFromWaitlistRequiresConsentAtom()` + edge test asserting `promoteFromWaitlist` writes a consent action.
4. **Fund lock idempotency** — `FundRepositoryTests.testLockTwiceEmitsOneAtom()` + edge `consistency_money` extension.
5. **Projection determinism** — `SpaceProjectionRepositoryTests.testRecomputeFromAtomsMatchesLive()` (replay test).
6. **Right state projection (iOS)** — `RightStateProjectionTests.testStatusTransitionsFromAtoms()`; today only edge-tested.
7. **GovernanceService XCTest → Swift Testing migration** — `Platform/GovernanceServiceTests.swift` is the only file still using XCTest in Core; modernize to `@Test`.
8. **ResourceLinkRepository edge guard** — `_tests/db/consistency_resource_links.test.ts` (does not exist).

## 8. Verdict per area

- **Core / Capabilities** — *healthy* (5 files overlap is the only issue).
- **Resources (variants/intents/activator)** — *healthy* (18 @Test against brand-new code; tests landed same day as code, 2026-05-18).
- **Resource repositories** — *partial* (Space/Slot/Booking/Fund/Right covered; ResourceLinkRepository has zero tests).
- **Features (Events, Fines, Votes, Rules, Onboarding)** — *adequate but fragile* (heavy inline stubs, one stale disabled test).
- **Notifications** — *partial* (rate limiting covered with bespoke fakes; no shared dispatcher mock).
- **UI** — *empty* (HappyPathTests permanently skipped since Phase 1 retirement).
- **Edge DB consistency** — *healthy* (10/11 doctrinal areas covered).
- **Edge e2e** — *healthy* (17 scenarios, but resource_links/booking-consent missing).

## 9. Beta blockers

1. `ResourceLinkRepository` ships with zero tests despite being load-bearing for the polymorphic detail page (`Plans/Active/HierarchyReference.md`).
2. `TandasUITests` target is empty — no smoke coverage of the founder onboarding flow that Beta 1 demos hinge on.
3. `OpenVotesCoordinatorTests.sectioned` disabled — orphan acknowledged but Open Votes pending/voted split is a Beta 1 surface.
4. `AddManualFineCoordinatorTests` reimplementing `MockGroupsRepository` inline means cascade-dependency bugs (mig 00170 + 00187/00188) won’t be caught by these tests.
5. No iOS-side capability-hiding doctrinal guard — risk of regression after the recent deletions of `GovernanceTabView`/`ManageCapabilitiesSheet`/`AdvancedCapabilitiesView`/`EditCapabilityConfigSheet` (no test would fail if a future commit re-added a capability toggle).
