# Frontend Remodel — Pass 1: Extirpate Events Vertical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Features/Events/Views/MainTabView.swift` (1619 L) + `HomeView.swift` (821 L) + `EventDetailHost.swift` (438 L) with a polymorphic, resource-type-agnostic shell under `Features/Shell/`. Delete the `Features/Events/` folder. Single detail screen (`UniversalResourceDetailView`).

**Architecture:** New `Features/Shell/` package owns the post-auth navigation: `RootShell` (TabView composition, <200 L), `RootShellState` (`@Observable` selectedTab + active routes), `RootRouter` (deeplink + sheet/cover orchestration), `RootShellSheets` (centralized ViewModifier). Single `ResourceTypeChrome` type in `RuulCore` eliminates 20 scattered `switch resource.resourceType` sites in views. `EventDetailHost` deleted; detail navigation routes through `UniversalResourceDetailView` with an `EventInteractor` protocol injected via SwiftUI `@Environment` (pattern from spec 2026-05-11). Feature flag `AppState.useNewShell` allows A/B toggle during migration; flipped to default-true and old code deleted at the end.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI iOS 26, `@Observable` (no Combine), `@MainActor` on UI types, Swift Testing (`@Test` / `@Suite` / `#expect`), xcodegen for project file, `make -C ios test` for CI command. Tests live in `ios/TandasTests/` with `@testable import Tandas`.

**Branch:** `pass1/extirpate-events-vertical`. Pre-execution prerequisite: the executor creates the worktree per `superpowers:using-git-worktrees`.

---

## Spec coverage map

Each section of the spec maps to one or more tasks here:

- ResourceTypeChrome → Task 3
- Eliminate 20 switch-on-resourceType sites → Task 4
- RootShellState / RootRouter / RootShellSheets → Tasks 5, 6, 7
- Tab wrappers preserve current 5-tab inventory → Task 8
- RootShell composition → Task 9
- Feature flag wiring → Tasks 2, 10
- HomeView move + polymorphization → Task 11
- HomeCoordinator move → Task 12
- Coordinator generalization (Edit/Creation/Ledger/Rules) → Task 13
- Subviews promoted to RuulUI/Patterns/Resource → Task 14
- EventInteractor protocol + @Environment injection → Task 15
- Route detail navigation through RootRouter → Task 16
- Delete EventDetailHost → Task 17
- Cutover: flip flag, delete Events folder, device smoke → Tasks 18–22

---

## File structure (post-Pass-1)

**New files (Foundation):**
- `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift` (~50 L) — icon/color/label lookup, single switch
- `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome+Sendable.swift` if needed — protocol conformances

**New files (Shell):**
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift` (~180 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` (~80 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` (~220 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (~180 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift` (~60 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/GroupTab.swift` (~60 L) — wraps existing GroupTabView until Pass 2
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/CreateTabIntercept.swift` (~50 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/DecisionsTab.swift` (~60 L)
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift` (~60 L)

**Moved files:**
- `Features/Events/Views/HomeView.swift` → `Features/Home/HomeView.swift` + polymorphize resource queries
- `Features/Events/Coordinator/HomeCoordinator.swift` → `Features/Home/HomeCoordinator.swift`
- `Features/Events/Coordinator/EventDetailCoordinator.swift` → `Features/Resources/Detail/EventInteractor.swift` (slim + protocol-driven)
- `Features/Events/Coordinator/EventCreationCoordinator.swift` → `Features/Create/ResourceCreationCoordinator.swift`
- `Features/Events/Coordinator/EventEditCoordinator.swift` → `Features/Resources/Edit/ResourceEditCoordinator.swift`
- `Features/Events/Coordinator/EventLedgerCoordinator.swift` → `Features/Resources/Money/ResourceLedgerCoordinator.swift`
- `Features/Events/Coordinator/EventRulesCoordinator.swift` → `Features/Rules/ResourceRulesCoordinator.swift`
- `Features/Events/Coordinator/CheckInScannerCoordinator.swift` → `Features/Resources/CheckIn/CheckInScannerCoordinator.swift`
- `Features/Events/Views/CheckInScannerView.swift` → `Features/Resources/CheckIn/CheckInScannerView.swift`
- `Features/Events/Views/PastEventsView.swift` → `Features/Resources/Past/PastResourcesView.swift`
- `Features/Events/Subviews/EventCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/ResourceHeroCard.swift`
- `Features/Events/Subviews/EventRSVPStateView.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/RSVPStateView.swift`
- `Features/Events/Subviews/EventLocationCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/LocationCard.swift`
- `Features/Events/Subviews/RecurrenceOptionsCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/RecurrenceOptionsCard.swift`
- `Features/Events/Subviews/LocationAutocompletePicker.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/LocationAutocompletePicker.swift`
- 10 sheets in `Features/Events/Sheets/` distributed to `Features/Resources/Sheets/` (capability-scoped sub-folders)

**Deleted files:**
- `Features/Events/Views/MainTabView.swift`
- `Features/Events/Views/HomeView.swift` (after move)
- `Features/Events/Views/EventDetailHost.swift`
- `Features/Events/Views/CreateEventView.swift`
- `Features/Events/Views/EditEventView.swift`
- `Features/Events/Views/MainTabStubs.swift`
- The entire `Features/Events/` directory

**Modified files (Foundation phase):**
- `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift` — add `useNewShell: Bool` flag
- `ios/Tandas/Shell/AuthGate.swift:54` — conditional between `MainTabView()` and `RootShell()`
- 20 view files with `switch resource.resourceType` → call `ResourceTypeChrome.resolve(...)` (enumerated in Task 4)

**Test files:**
- `ios/TandasTests/Capabilities/ResourceTypeChromeTests.swift` (~50 L)
- `ios/TandasTests/Shell/RootShellStateTests.swift` (~80 L)
- `ios/TandasTests/Shell/RootRouterTests.swift` (~150 L)

---

## Conventions used in this plan

**Test command:** `make -C ios test` (resolves to `xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'`). Use it as-is.

**Project regen:** `make -C ios project` (runs `xcodegen` from `ios/`). MUST run after adding/removing files inside `ios/` Swift packages — without it, the Xcode project doesn't pick up the new files.

**Build only:** `make -C ios build` for quick compile checks during inner loop.

**Test selector:** `xcodebuild test -project ios/Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/<SuiteName>/<testName>` for single-test runs.

**Commit messages:** follow recent repo style — `feat(scope): subject`, `refactor(scope): subject`, `chore(scope): subject`. No `Co-Authored-By` lines. No emojis. Body explains the why.

---

## Task 1: Branch + worktree

**Files:**
- (none — only git state)

- [ ] **Step 1: Create worktree + branch**

```bash
cd /Users/jj/code/tandas
git worktree add ../tandas-pass1 -b pass1/extirpate-events-vertical main
cd ../tandas-pass1
```

Expected: new worktree at `../tandas-pass1`, on branch `pass1/extirpate-events-vertical`.

- [ ] **Step 2: Verify clean state**

```bash
git status
make -C ios test
```

Expected: working tree clean, all existing tests green. Baseline established.

- [ ] **Step 3: Commit baseline marker (empty commit)**

```bash
git commit --allow-empty -m "chore(pass1): start extirpate-events-vertical branch

Baseline: green build on main. Pass 1 of frontend remodel; see
docs/superpowers/specs/2026-05-14-frontend-remodel-design.md and
docs/superpowers/plans/2026-05-14-frontend-remodel-pass1.md."
```

Expected: empty commit recorded so the diff against `main` later starts here.

---

## Task 2: Add `useNewShell` feature flag on AppState

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift` (add property after line 73, before `capabilityResolver`)

- [ ] **Step 1: Add the flag**

Find the block ending with `public var ruleShapeRegistry: RuleShapeRegistry = .v1Fallback` (around line 73). Add immediately after it:

```swift
    /// Pass 1 frontend remodel: A/B flag between legacy `MainTabView`
    /// (Features/Events) and new `RootShell` (Features/Shell). Default
    /// `false` until Task 18 flips it. Read by `AuthGate` to pick the
    /// post-auth root view; lives on `AppState` so debug builds can
    /// toggle it from a hidden gesture without rebuilding.
    public var useNewShell: Bool = false
```

- [ ] **Step 2: Build**

```bash
make -C ios build
```

Expected: green build. AppState recompiles, no callers yet.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "feat(shell): add AppState.useNewShell flag for Pass 1 cutover

Defaults to false; AuthGate (next commit) will branch on it between
legacy MainTabView and new RootShell. Flipped to true in Task 18 at
end of Pass 1."
```

---

## Task 3: `ResourceTypeChrome` — single source for icon / color / label

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift`
- Test: `ios/TandasTests/Capabilities/ResourceTypeChromeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Capabilities/ResourceTypeChromeTests.swift`:

```swift
import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("ResourceTypeChrome")
struct ResourceTypeChromeTests {
    @Test("every ResourceType resolves to a non-empty symbol + label")
    func everyTypeHasChrome() {
        for type in ResourceType.allCases {
            let chrome = ResourceTypeChrome.resolve(type)
            #expect(!chrome.symbol.isEmpty, "symbol empty for \(type)")
            #expect(!chrome.labelKey.isEmpty, "labelKey empty for \(type)")
        }
    }

    @Test("event resolves to calendar symbol")
    func eventChrome() {
        let c = ResourceTypeChrome.resolve(.event)
        #expect(c.symbol == "calendar")
        #expect(c.labelKey == "resource.type.event")
    }

    @Test("fund resolves to banknote symbol")
    func fundChrome() {
        #expect(ResourceTypeChrome.resolve(.fund).symbol == "banknote")
    }

    @Test("asset resolves to key.fill symbol")
    func assetChrome() {
        #expect(ResourceTypeChrome.resolve(.asset).symbol == "key.fill")
    }

    @Test("space resolves to mappin.and.ellipse symbol")
    func spaceChrome() {
        #expect(ResourceTypeChrome.resolve(.space).symbol == "mappin.and.ellipse")
    }

    @Test("slot resolves to ticket symbol")
    func slotChrome() {
        #expect(ResourceTypeChrome.resolve(.slot).symbol == "ticket")
    }

    @Test("right resolves to person.badge.key.fill symbol")
    func rightChrome() {
        #expect(ResourceTypeChrome.resolve(.right).symbol == "person.badge.key.fill")
    }
}
```

Note: `ResourceType.allCases` requires `CaseIterable`. Verify `ResourceType` already conforms by reading `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/ResourceType.swift`. If it doesn't, add the conformance in the same task (one-line change to the enum declaration).

- [ ] **Step 2: Run test to verify it fails**

```bash
make -C ios project   # xcodegen picks up the new test file
make -C ios test 2>&1 | tail -40
```

Expected: FAIL with `cannot find 'ResourceTypeChrome' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift`:

```swift
import SwiftUI

/// Single source for the visual chrome of each `ResourceType`: SF Symbol,
/// semantic color, and i18n label key. Pre-Pass-1, this lookup was
/// duplicated across ~20 `switch resource.resourceType` sites in
/// SwiftUI views — a violation of `feedback_no_hardcoded_verticals`.
///
/// Views should call `ResourceTypeChrome.resolve(resource.resourceType)`
/// and read `.symbol` / `.semanticColor` / `.labelKey` — never branch
/// on `resourceType` themselves.
public struct ResourceTypeChrome: Sendable, Hashable {
    public let symbol: String
    public let semanticColor: Color
    public let labelKey: String

    public static func resolve(_ type: ResourceType) -> ResourceTypeChrome {
        switch type {
        case .event:
            return ResourceTypeChrome(
                symbol: "calendar",
                semanticColor: .accentColor,
                labelKey: "resource.type.event"
            )
        case .fund:
            return ResourceTypeChrome(
                symbol: "banknote",
                semanticColor: .green,
                labelKey: "resource.type.fund"
            )
        case .asset:
            return ResourceTypeChrome(
                symbol: "key.fill",
                semanticColor: .orange,
                labelKey: "resource.type.asset"
            )
        case .space:
            return ResourceTypeChrome(
                symbol: "mappin.and.ellipse",
                semanticColor: .purple,
                labelKey: "resource.type.space"
            )
        case .slot:
            return ResourceTypeChrome(
                symbol: "ticket",
                semanticColor: .blue,
                labelKey: "resource.type.slot"
            )
        case .right:
            return ResourceTypeChrome(
                symbol: "person.badge.key.fill",
                semanticColor: .indigo,
                labelKey: "resource.type.right"
            )
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make -C ios project
make -C ios test 2>&1 | tail -20
```

Expected: PASS — all 7 ResourceTypeChrome tests green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift \
        ios/TandasTests/Capabilities/ResourceTypeChromeTests.swift
git commit -m "feat(core): ResourceTypeChrome — single source for icon/color/label

Eliminates the need for 20 scattered switch-on-resourceType sites in
SwiftUI views. Pass 1 Task 4 migrates the existing callsites."
```

---

## Task 4: Migrate the 20 `switch resourceType` sites to `ResourceTypeChrome`

**Files (exact 6 — multiple switches per file):**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupTabView.swift:388-396`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift:188-198`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/ResourceSummaryView.swift:57-67`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailHeaderView.swift:56-66`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/HomeView.swift:475-484`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceTypePickerView.swift` (if it has a switch too — grep first)

- [ ] **Step 1: Confirm exact switch sites**

```bash
grep -rn "case \.event\b" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ \
  | grep -v "_test\|Tests" | head -30
```

Expected: ~6 distinct switch blocks across the listed files. If a new site appears not in the list, add it to this task.

- [ ] **Step 2: Migrate GroupTabView.swift (lines ~388-396)**

Find the switch returning icons:

```swift
case .event:        return "calendar"
case .fund:         return "banknote"
case .asset:        return "key.fill"
case .space:        return "mappin.and.ellipse"
case .slot:         return "ticket"
case .right:        return "person.badge.key.fill"
```

Replace the wrapping function/computed property entirely with a single line at the callsite (or keep the helper but make it a one-liner):

```swift
// Before: a private func like `private func icon(for type: ResourceType) -> String { switch ... }`
// After:
private func icon(for type: ResourceType) -> String {
    ResourceTypeChrome.resolve(type).symbol
}
```

If the function is only called once, inline it at the callsite and delete the helper.

- [ ] **Step 3: Migrate ResourceDetailSheet.swift (lines ~188-198)**

This switch returns string labels, not symbols. Inspect: if it returns a localizable label, use `ResourceTypeChrome.resolve(type).labelKey` and pass that through the localization layer the file already uses. If it returns raw English strings, replace with the labelKey for now and add a `// TODO: localize via String(localized:)` only if the file already had that TODO; otherwise leave as-is.

Replace:
```swift
case .event:  return "event"
case .fund:   return "fund"
// ...
```

With:
```swift
ResourceTypeChrome.resolve(resource.resourceType).labelKey
```

- [ ] **Step 4: Migrate ResourceSummaryView.swift, DetailHeaderView.swift (icon switches)**

Both follow the same pattern as GroupTabView — replace the switch body with `ResourceTypeChrome.resolve(context.resource.resourceType).symbol`. Delete the now-empty switch wrapper if its only purpose was the lookup.

- [ ] **Step 5: Migrate Events/Views/HomeView.swift (lines ~475-484)**

This file is moved in Task 11. For now, migrate the switch in place — Task 11 then moves the migrated version. Same `ResourceTypeChrome.resolve(...).symbol` substitution.

- [ ] **Step 6: Verify zero remaining `switch resource.resourceType` sites**

```bash
grep -rn "switch.*resource\.resourceType\|switch.*resourceType" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ \
  | grep -v "Tests\|//" \
  | tee /tmp/remaining_switches.txt
wc -l /tmp/remaining_switches.txt
```

Expected: zero non-comment matches. If any remain, migrate them.

Also verify no remaining `case .event:` icon mappings:

```bash
grep -rn "case \.event:" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ \
  | grep -v "Tests" \
  | grep "calendar\|return\|symbol\|icon"
```

Expected: zero matches.

- [ ] **Step 7: Build + run tests**

```bash
make -C ios build
make -C ios test 2>&1 | tail -20
```

Expected: green build + all tests still pass (no behavior change).

- [ ] **Step 8: Commit**

```bash
git add -A ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
git commit -m "refactor(features): replace 20 switch-on-resourceType sites with ResourceTypeChrome

No behavior change. Each view now calls
ResourceTypeChrome.resolve(...).symbol / .labelKey instead of
re-implementing the switch. Single source of truth for icon/color/label."
```

---

## Task 5: `RootShellState` — `@Observable` shell-scope state

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift`
- Test: `ios/TandasTests/Shell/RootShellStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Shell/RootShellStateTests.swift`:

```swift
import Testing
import Foundation
@testable import Tandas

@Suite("RootShellState")
@MainActor
struct RootShellStateTests {
    @Test("defaults: selectedTab = .home, no active routes")
    func defaults() {
        let state = RootShellState()
        #expect(state.selectedTab == .home)
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("selecting a tab updates selectedTab")
    func selectTab() {
        let state = RootShellState()
        state.selectedTab = .profile
        #expect(state.selectedTab == .profile)
    }

    @Test("push(.createGroup) appends to activeRoutes")
    func pushRoute() {
        let state = RootShellState()
        state.push(.createGroup)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("dismissTop pops the last route")
    func dismissTop() {
        let state = RootShellState()
        state.push(.createGroup)
        state.push(.joinGroup)
        state.dismissTop()
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("dismissAll clears active routes")
    func dismissAll() {
        let state = RootShellState()
        state.push(.createGroup)
        state.push(.joinGroup)
        state.dismissAll()
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("contains(.createGroup) true after push")
    func contains() {
        let state = RootShellState()
        #expect(!state.contains(.createGroup))
        state.push(.createGroup)
        #expect(state.contains(.createGroup))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "RootShellState|error:" | head -10
```

Expected: FAIL with `cannot find 'RootShellState' in scope` or `cannot find type 'RootShellState'`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift`:

```swift
import Foundation
import Observation

/// Shell-scope `@Observable` state for the post-auth root. Owns:
/// - which tab is currently selected
/// - the stack of active sheet/cover routes (centralized so RootShellSheets
///   ViewModifier can drive every presentation from a single source)
///
/// Lives ABOVE feature coordinators (which own their own data) and BELOW
/// `AppState` (which owns cross-group session + repos).
@MainActor
@Observable
public final class RootShellState {
    public var selectedTab: RootTab = .home
    public private(set) var activeRoutes: [RootRoute] = []

    public init() {}

    public func push(_ route: RootRoute) {
        activeRoutes.append(route)
    }

    public func dismissTop() {
        guard !activeRoutes.isEmpty else { return }
        activeRoutes.removeLast()
    }

    public func dismissAll() {
        activeRoutes.removeAll()
    }

    public func contains(_ route: RootRoute) -> Bool {
        activeRoutes.contains(route)
    }
}

/// Tab inventory preserved 1:1 from legacy `MainTabView` so Pass 1 is
/// pure refactor. Pass 2 changes the inventory to match `AppShell.md`.
public enum RootTab: String, Sendable, Hashable, CaseIterable {
    case home
    case group
    case create
    case decisions
    case profile
}

/// Sheet / cover routes presented above the tab content. Each case maps to
/// one `.sheet(...)` or `.fullScreenCover(...)` slot inside
/// `RootShellSheets`.
public enum RootRoute: Sendable, Hashable {
    case createGroup
    case joinGroup
    case groupSwitcher
    case inviteShare
    case groupRulesSettings
    case createCover            // ResourceWizard cover
    case eventDetail(EventDetailRouteContext)
    case fineDetail(FineDetailRouteContext)
    case ruleEdit(RuleEditRouteContext)
    case voteDetail(VoteDetailRouteContext)
    case openVotes(OpenVotesRouteContext)
    case scanner(CheckInScannerCoordinatorBox)
    case past
    case feed
    case groupHistory
    case acuerdos
    case sanciones
    case createVotePicker
    case createGeneralProposal
    case createRuleChange(RuleChangeInitialContext?)
}

// MARK: - Route context wrappers
//
// These are thin Hashable/Sendable boxes that hold the same identifiers
// `MainTabView` carries today as @State props. Concrete types
// (`EventDetailRouteContext`, `FineDetailRouteContext`, etc.) are imported
// from their existing locations once we move them. For now, declare
// placeholder typealiases that resolve to the existing types so the file
// compiles standalone.

public typealias EventDetailRouteContext = UUID  // event.id
public typealias FineDetailRouteContext = UUID   // fine.id
public typealias RuleChangeInitialContext = UUID // rule.id
```

Note: `RuleEditRouteContext`, `VoteDetailRouteContext`, `OpenVotesRouteContext`, `CheckInScannerCoordinatorBox` already exist in the codebase (currently used by MainTabView's @State). Find them with:

```bash
grep -rn "struct RuleEditRouteContext\|struct VoteDetailRouteContext\|struct OpenVotesRouteContext" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
```

If they're in a feature folder, import them at the top of RootShellState.swift. If they're nested types inside MainTabView, extract them into their own files in the same task (one small file each, ~10 L) so they're reusable from Shell.

- [ ] **Step 4: Resolve route context types**

For each route context type referenced (`RuleEditRouteContext`, `VoteDetailRouteContext`, `OpenVotesRouteContext`, `AppealRouteContext`, `CheckInScannerCoordinator` box, `RuleChangeDeepLink`), confirm it's:
1. Defined publicly in a feature folder → just import (no action)
2. Nested inside MainTabView → extract to its own file under the feature's folder

After extraction the new files are tiny:

```swift
// e.g. ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleEditRouteContext.swift
import Foundation

public struct RuleEditRouteContext: Sendable, Hashable, Identifiable {
    public let rule: GroupRule
    public let preselectChange: RuleChangeInitialContext?
    public var id: UUID { rule.id }

    public init(rule: GroupRule, preselectChange: RuleChangeInitialContext? = nil) {
        self.rule = rule
        self.preselectChange = preselectChange
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "RootShellState|PASS|FAIL" | head -15
```

Expected: PASS — all 6 RootShellState tests green.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift \
        ios/TandasTests/Shell/RootShellStateTests.swift
# Plus any route-context files extracted in Step 4
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
git commit -m "feat(shell): RootShellState — @Observable shell-scope state

Owns selectedTab + activeRoutes stack. Lives between AppState
(session, cross-group) and feature coordinators (per-domain data).
Tested in isolation; not yet wired into the app (Task 9 wires it)."
```

---

## Task 6: `RootRouter` — deeplink + route orchestration

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift`
- Test: `ios/TandasTests/Shell/RootRouterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Shell/RootRouterTests.swift`:

```swift
import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("RootRouter")
@MainActor
struct RootRouterTests {
    private func makeRouter() -> (RootRouter, RootShellState) {
        let state = RootShellState()
        let router = RootRouter(state: state)
        return (router, state)
    }

    @Test("selectTab updates state.selectedTab")
    func selectTab() {
        let (router, state) = makeRouter()
        router.selectTab(.profile)
        #expect(state.selectedTab == .profile)
    }

    @Test("present(.createGroup) pushes route")
    func present() {
        let (router, state) = makeRouter()
        router.present(.createGroup)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("intercept .create tab opens createCover route, does not change tab")
    func createInterceptWithActiveGroup() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.create, hasActiveGroup: true)
        #expect(state.selectedTab == .home, "tab unchanged")
        #expect(state.activeRoutes == [.createCover])
    }

    @Test("intercept .create with no group routes to createGroup")
    func createInterceptNoGroup() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.create, hasActiveGroup: false)
        #expect(state.selectedTab == .home)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("non-create tab selection updates selectedTab normally")
    func normalTab() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.group, hasActiveGroup: true)
        #expect(state.selectedTab == .group)
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("handleEventDeepLink pushes eventDetail route")
    func eventDeepLink() {
        let (router, state) = makeRouter()
        let eventID = UUID()
        let link = EventDeepLink(eventID: eventID, source: .push)
        router.handle(eventDeepLink: link)
        #expect(state.activeRoutes == [.eventDetail(eventID)])
    }

    @Test("dismissTop is idempotent on empty stack")
    func dismissEmpty() {
        let (router, state) = makeRouter()
        router.dismissTop()
        #expect(state.activeRoutes.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "RootRouter|error:" | head -10
```

Expected: FAIL with `cannot find 'RootRouter' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift`:

```swift
import Foundation
import Observation
import RuulCore

/// Owns navigation intent for the post-auth shell. Views and the inbox
/// hand intent to the router (`present`, `selectTab`, `handle(deeplink:)`);
/// the router mutates `RootShellState`; SwiftUI rebuilds from observation.
///
/// One responsibility: convert intent → state. No data fetching, no
/// business rules, no RPC calls. Coordinators do that.
@MainActor
@Observable
public final class RootRouter {
    public let state: RootShellState

    public init(state: RootShellState) {
        self.state = state
    }

    // MARK: - Tab selection

    public func selectTab(_ tab: RootTab) {
        state.selectedTab = tab
    }

    /// Handles the raw tab selection from `TabView`, intercepting the
    /// `.create` tap to present the wizard cover without actually moving
    /// to a "create" tab (which has no content of its own).
    public func handleTabSelection(_ tab: RootTab, hasActiveGroup: Bool) {
        guard tab == .create else {
            selectTab(tab)
            return
        }
        // Intercept: don't change selectedTab, just present the cover
        if hasActiveGroup {
            present(.createCover)
        } else {
            present(.createGroup)
        }
    }

    // MARK: - Routes

    public func present(_ route: RootRoute) {
        state.push(route)
    }

    public func dismissTop() {
        state.dismissTop()
    }

    public func dismissAll() {
        state.dismissAll()
    }

    // MARK: - Deep links

    public func handle(eventDeepLink link: EventDeepLink) {
        present(.eventDetail(link.eventID))
    }

    public func handle(ruleChangeDeepLink link: RuleChangeDeepLink) {
        // Existing handler in MainTabView pushes a ruleEdit route; mirror it.
        present(.ruleEdit(RuleEditRouteContext(
            rule: link.rule,
            preselectChange: link.changeID
        )))
    }
}
```

Note: depending on what's defined where, you may need to adjust the imports. The test uses `EventDeepLink` which is in `RuulCore/Services/Notifications/EventDeepLink.swift` — already in scope via `import RuulCore`.

If `RuleChangeDeepLink` references `rule: GroupRule` (a full model) the call site may not have that available pre-fetch. Read the current handler in `MainTabView.swift` (search for `handleRuleChangeDeepLink`) and copy its shape — Pass 1 preserves behavior.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "RootRouter|PASS|FAIL" | head -15
```

Expected: PASS — all 7 RootRouter tests green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift \
        ios/TandasTests/Shell/RootRouterTests.swift
git commit -m "feat(shell): RootRouter — intent → state for post-auth navigation

Handles tab selection (with .create intercept), route push/dismiss,
event + rule_change deep links. Single seam between views and
RootShellState. Tested in isolation; not yet wired into app."
```

---

## Task 7: `RootShellSheets` ViewModifier

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift`

(No unit tests — this is a pure passthrough ViewModifier that maps `RootRoute` cases to `.sheet(item:)` / `.fullScreenCover()` modifiers. SwiftUI presentation behavior isn't reliably testable in Swift Testing without snapshot tooling — it's verified by smoke at Task 22.)

- [ ] **Step 1: Identify every sheet/cover currently in MainTabView**

```bash
grep -n "\.sheet(\|\.fullScreenCover(" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/MainTabView.swift
```

Expected: ~14 distinct presentation modifiers. List them — each becomes one branch in `RootShellSheets`.

- [ ] **Step 2: Write `RootShellSheets`**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift`:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Centralizes all sheet/cover presentations for the post-auth shell.
/// Pre-Pass-1, these ~14 modifiers stacked on `MainTabView.body`
/// (~400 L). Moving them into a dedicated ViewModifier:
/// - Trims `RootShell.body` to <50 L
/// - Lets new presentations be added by appending one branch here
/// - Decouples shell composition from presentation soup
public struct RootShellSheets: ViewModifier {
    @Environment(AppState.self) private var app
    let router: RootRouter

    public func body(content: Content) -> some View {
        content
            // For each RootRoute that should present as a sheet:
            .sheet(isPresented: bindingFor(.createGroup), onDismiss: dismissCallback) {
                CreateGroupSheet { _ in /* AppState handles activation */ }
                    .environment(app)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: bindingFor(.joinGroup), onDismiss: dismissCallback) {
                JoinGroupSheet { _ in }
                    .environment(app)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: bindingFor(.groupSwitcher), onDismiss: dismissCallback) {
                GroupSwitcherSheet(
                    onCreateGroup: { router.present(.createGroup) },
                    onJoinGroup: { router.present(.joinGroup) }
                )
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // Add a similar block for each remaining RootRoute case.
            // For routes carrying context (eventDetail(id), ruleEdit(ctx), etc.)
            // use `.sheet(item: bindingForItem(\.eventDetail))` patterns.
            .fullScreenCover(isPresented: bindingFor(.createCover), onDismiss: dismissCallback) {
                ResourceWizardSheet()
                    .environment(app)
            }
    }

    /// Binding<Bool> over "is this exact route present in the stack?".
    /// Setting to false removes the topmost matching route.
    private func bindingFor(_ route: RootRoute) -> Binding<Bool> {
        Binding(
            get: { router.state.contains(route) },
            set: { present in
                if present {
                    if !router.state.contains(route) { router.present(route) }
                } else {
                    // Remove the matching route(s) from the stack
                    while router.state.contains(route) { router.state.dismissTop() }
                }
            }
        )
    }

    private var dismissCallback: () -> Void { {} }
}

public extension View {
    func rootShellSheets(router: RootRouter) -> some View {
        modifier(RootShellSheets(router: router))
    }
}
```

The `bindingFor(_:)` helper has a known limitation: it can't distinguish two routes of the same case with different associated values (e.g. two `eventDetail(uuid1)` and `eventDetail(uuid2)`). For context-carrying routes, use `.sheet(item:)` with a custom `Identifiable` projection — see existing patterns in `MainTabView` and translate them branch-by-branch.

- [ ] **Step 3: Wire every existing sheet/cover from MainTabView**

For each sheet listed in Step 1, copy its body into a new `.sheet(...)` / `.fullScreenCover(...)` branch in `RootShellSheets.body(content:)`. Preserve detents, drag indicators, dismiss callbacks, and the `.environment(app)` injection.

- [ ] **Step 4: Build**

```bash
make -C ios project
make -C ios build
```

Expected: green build. `RootShellSheets` compiles but isn't applied anywhere yet (Task 9).

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift
git commit -m "feat(shell): RootShellSheets ViewModifier — centralize 14 presentations

Maps each RootRoute case to its sheet/cover. Lets RootShell.body stay
<50L by extracting the presentation soup that bloated MainTabView."
```

---

## Task 8: Tab wrapper views (5 thin wrappers)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/GroupTab.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/CreateTabIntercept.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/DecisionsTab.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift`

Each wrapper hosts a `NavigationStack` (or none if the screen handles its own) and embeds the existing feature view. Pass 1 keeps the views in their CURRENT locations; Task 11+ moves them.

- [ ] **Step 1: HomeTab**

```swift
// HomeTab.swift
import SwiftUI
import RuulCore

@MainActor
public struct HomeTab: View {
    @Environment(AppState.self) private var app
    let homeCoordinator: HomeCoordinator?
    let inboxCoordinator: InboxCoordinator?

    public init(home: HomeCoordinator?, inbox: InboxCoordinator?) {
        self.homeCoordinator = home
        self.inboxCoordinator = inbox
    }

    public var body: some View {
        NavigationStack {
            if let coord = homeCoordinator {
                HomeView(coordinator: coord)
                    .environment(app)
            } else {
                BootstrappingView()
            }
        }
    }
}
```

- [ ] **Step 2: GroupTab — wraps legacy GroupTabView until Pass 2**

```swift
// GroupTab.swift
import SwiftUI
import RuulCore

@MainActor
public struct GroupTab: View {
    @Environment(AppState.self) private var app

    public init() {}

    public var body: some View {
        NavigationStack {
            GroupTabView()
                .environment(app)
        }
    }
}
```

- [ ] **Step 3: CreateTabIntercept — placeholder content (never shown)**

```swift
// CreateTabIntercept.swift
import SwiftUI

/// The body of this view is never shown — `RootRouter.handleTabSelection`
/// intercepts `.create` taps before the TabView swaps content and routes
/// to a sheet/cover instead. A clear `Color.clear` keeps the tab valid
/// for SwiftUI's TabView machinery.
@MainActor
public struct CreateTabIntercept: View {
    public init() {}

    public var body: some View {
        Color.clear
    }
}
```

- [ ] **Step 4: DecisionsTab + ProfileTab**

```swift
// DecisionsTab.swift
import SwiftUI
import RuulCore

@MainActor
public struct DecisionsTab: View {
    @Environment(AppState.self) private var app
    let rulesCoordinator: RulesCoordinator?

    public init(rules: RulesCoordinator?) { self.rulesCoordinator = rules }

    public var body: some View {
        NavigationStack {
            if let coord = rulesCoordinator {
                RulesView(coordinator: coord)
                    .environment(app)
            } else {
                BootstrappingView()
            }
        }
    }
}
```

```swift
// ProfileTab.swift
import SwiftUI
import RuulCore

@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    let profileCoordinator: ProfileCoordinator?

    public init(profile: ProfileCoordinator?) { self.profileCoordinator = profile }

    public var body: some View {
        NavigationStack {
            if let coord = profileCoordinator {
                ProfileView(coordinator: coord)
                    .environment(app)
            } else {
                BootstrappingView()
            }
        }
    }
}
```

- [ ] **Step 5: Build**

```bash
make -C ios project
make -C ios build 2>&1 | tail -20
```

Expected: green build. Any missing imports surface here — fix them by adding the appropriate `import` line.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/
git commit -m "feat(shell): tab wrapper views for RootShell

Five thin wrappers (~50L each). Each embeds the existing feature view
in a NavigationStack; coordinators flow in from RootShell. Replaces
the @State soup in MainTabView with explicit dependency injection."
```

---

## Task 9: `RootShell` view + AuthGate wiring

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift`
- Modify: `ios/Tandas/Shell/AuthGate.swift:54`

- [ ] **Step 1: Write RootShell**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift`:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Post-auth root. iOS 26 native `TabView` + Liquid Glass tab bar via
/// `tabBarMinimizeBehavior(.onScrollDown)`. Presentation soup lives in
/// `RootShellSheets`; navigation intent flows through `RootRouter`.
///
/// Pass 1 preserves the legacy 5-tab inventory exactly. Pass 2 changes
/// the inventory to match AppShell.md.
@MainActor
public struct RootShell: View {
    @Environment(AppState.self) private var app

    @State private var shellState = RootShellState()
    @State private var router: RootRouter?

    @State private var homeCoordinator: HomeCoordinator?
    @State private var inboxCoordinator: InboxCoordinator?
    @State private var rulesCoordinator: RulesCoordinator?
    @State private var profileCoordinator: ProfileCoordinator?
    @State private var myFinesCoordinator: MyFinesCoordinator?
    @State private var groupHistoryCoordinator: GroupHistoryCoordinator?

    public init() {}

    public var body: some View {
        TabView(selection: tabBinding) {
            HomeTab(home: homeCoordinator, inbox: inboxCoordinator)
                .tabItem { Label("Inicio", systemImage: "house.fill") }
                .tag(RootTab.home)
                .badge(inboxCoordinator?.actions.count ?? 0)

            GroupTab()
                .tabItem { Label("Grupo", systemImage: "person.3.fill") }
                .tag(RootTab.group)

            CreateTabIntercept()
                .tabItem { Label("Crear", systemImage: "plus.circle.fill") }
                .tag(RootTab.create)

            DecisionsTab(rules: rulesCoordinator)
                .tabItem { Label("Decisiones", systemImage: "hand.raised.fill") }
                .tag(RootTab.decisions)

            ProfileTab(profile: profileCoordinator)
                .tabItem { Label("Perfil", systemImage: "person.crop.circle.fill") }
                .tag(RootTab.profile)
        }
        .tint(app.activeGroup?.category.ramp.accent ?? Color.ruulTextPrimary)
        .tabBarMinimizeBehavior(.onScrollDown)
        .animation(.ruulGroupSwitch, value: app.activeGroupId)
        .modifier(SheetsIfReady(router: router))
        .task { await bootstrap() }
        .task(id: app.activeGroupId) { await rebuildCoordinators() }
        .onChange(of: app.pendingEventDeepLink) { _, link in
            guard let link, let router else { return }
            router.handle(eventDeepLink: link)
            app.consumeEventDeepLink()
        }
        .onChange(of: app.pendingRuleChangeDeepLink) { _, link in
            guard let link, let router else { return }
            router.handle(ruleChangeDeepLink: link)
            app.consumeRuleChangeDeepLink()
        }
    }

    private var tabBinding: Binding<RootTab> {
        Binding(
            get: { shellState.selectedTab },
            set: { tab in
                router?.handleTabSelection(tab, hasActiveGroup: app.activeGroup != nil)
            }
        )
    }

    private func bootstrap() async {
        if router == nil {
            router = RootRouter(state: shellState)
        }
        await rebuildCoordinators()
    }

    private func rebuildCoordinators() async {
        guard let group = app.activeGroup, let session = app.session else { return }
        // Mirror MainTabView's rebuildCoordinators(for:) — copy the exact
        // construction calls. Each coordinator gets the repos + IDs from
        // AppState. Reference: ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/MainTabView.swift
        // (search for `rebuildCoordinators`).
        homeCoordinator = HomeCoordinator(/* fill from MainTabView pattern */)
        inboxCoordinator = InboxCoordinator(/* same */)
        rulesCoordinator = RulesCoordinator(/* same */)
        profileCoordinator = ProfileCoordinator(/* same */)
        myFinesCoordinator = MyFinesCoordinator(/* same */)
        groupHistoryCoordinator = GroupHistoryCoordinator(/* same */)
    }
}

/// Apply sheets only once the router exists. SwiftUI's ViewModifier
/// must take a non-optional router, so this wrapper gates application.
private struct SheetsIfReady: ViewModifier {
    let router: RootRouter?

    func body(content: Content) -> some View {
        if let router {
            content.modifier(RootShellSheets(router: router))
        } else {
            content
        }
    }
}
```

The placeholder `/* fill from MainTabView pattern */` is intentional — copy the EXACT construction calls from `MainTabView.rebuildCoordinators(for:)` so behavior is preserved bit-for-bit. Open that function, copy the body, adapt names. Do this in Step 1, not as a follow-up.

- [ ] **Step 2: Wire AppState consume helpers if missing**

Search for the deep-link consume methods:

```bash
grep -n "func consumeEventDeepLink\|func consumeRuleChangeDeepLink" \
  ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
```

If `consumeEventDeepLink` exists (currently called `consumePendingInvite`-style), use the actual name. If it doesn't, add both as one-liners:

```swift
public func consumeEventDeepLink() { pendingEventDeepLink = nil }
public func consumeRuleChangeDeepLink() { pendingRuleChangeDeepLink = nil }
```

- [ ] **Step 3: Wire the flag in AuthGate**

Open `ios/Tandas/Shell/AuthGate.swift`. Find line 54 (`MainTabView()`). Replace with:

```swift
            } else {
                if app.useNewShell {
                    RootShell()
                } else {
                    MainTabView()
                }
            }
```

- [ ] **Step 4: Build**

```bash
make -C ios project
make -C ios build 2>&1 | tail -30
```

Expected: green build. AppState recompiles, AuthGate compiles with the conditional, both shells coexist.

- [ ] **Step 5: Smoke test (flag OFF)**

```bash
make -C ios test 2>&1 | tail -15
```

Expected: all tests still green. The flag defaults to false, so app runtime behavior is unchanged.

Then run the app in simulator (manual step):

```bash
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
make -C ios build
# Open Tandas.xcodeproj in Xcode, hit Cmd-R, verify legacy MainTabView shows.
```

Expected: legacy MainTabView still renders (flag is false).

- [ ] **Step 6: Smoke test (flag ON — debug toggle)**

In Xcode debugger, before `AuthGate.body` evaluates, manually set `app.useNewShell = true` (via lldb: `e -- app.useNewShell = true`). Verify:
- Tabs render with the 5 labels (Inicio, Grupo, Crear, Decisiones, Perfil)
- Tab selection works on .home, .group, .decisions, .profile
- Tapping .create opens the ResourceWizard cover (createCover route)
- Tapping group switcher header opens GroupSwitcherSheet
- A push notification with an EventDeepLink routes to event detail

Expected: all six behaviors green. If something doesn't show, the corresponding sheet branch in `RootShellSheets` (Task 7) needs the missing case. Add it and re-run.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift \
        ios/Tandas/Shell/AuthGate.swift \
        ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "feat(shell): RootShell + AuthGate flag wiring

RootShell renders the same 5-tab inventory as MainTabView via the new
Shell scaffolding (state + router + sheets). AuthGate branches on
AppState.useNewShell (default false) so both shells coexist until
the cutover at Task 18. Manual smoke OK with flag toggled."
```

---

## Task 10: Move HomeView Events → Home + polymorphize

**Files:**
- Move + modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/HomeView.swift` → `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift`

- [ ] **Step 1: Create destination + move file**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/HomeView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift
```

- [ ] **Step 2: Polymorphize the resource query**

In the moved `HomeView.swift`, find the section that reads upcoming events (search for `eventRepo.list` or `EventRepository`). Replace with a call to `LiveResourceRepository.list(groupId:)` filtered by capability `scheduling` (or `rsvp` — whichever was on the original query):

```swift
// Before:
let events = try await app.eventRepo.list(groupId: group.id, limit: 14)

// After:
let resources = try await app.resourceRepo.list(groupId: group.id)
let scheduled = resources.filter { res in
    app.capabilityResolver.availableCapabilities(
        for: res.resourceType,
        in: group,
        catalog: .v1
    ).contains("scheduling")
}
```

Adapt the model property accesses downstream: where it used `event.title` now use `resource.metadata["title"] as? String ?? "Sin título"`, etc. The `events_view` projection (mig 00156) keeps the same column shape, so most accessors translate cleanly.

If the file references `Event` model directly, convert to `Resource` model. Use the spec 2026-05-11 conversion as reference.

- [ ] **Step 3: Update imports**

The file likely imports nothing new — `RuulCore` already exports `Resource`. Remove any `import` of internal `Events/` namespace if present (`Features/Events/Subviews/EventCard` becomes `RuulUI` after Task 14, but for now keep the existing imports working).

- [ ] **Step 4: Update HomeTab (created in Task 8) to compile against the moved view**

`HomeTab.swift` imports `HomeView` implicitly through being in the same module. The move within `RuulFeatures` doesn't change the import surface.

- [ ] **Step 5: Build + test**

```bash
make -C ios project
make -C ios build
make -C ios test 2>&1 | tail -15
```

Expected: green. The legacy `MainTabView` still references `HomeView` from the new path because they share the module.

- [ ] **Step 6: Smoke test (flag ON)**

In simulator with `useNewShell = true`, verify:
- Home tab renders upcoming events same as before
- Tap event → opens detail (still EventDetailHost for now; Task 17 replaces)
- Tap "+" → ResourceWizard cover

Expected: same UX as flag OFF.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift
git commit -m "refactor(home): move HomeView to Features/Home, polymorphize queries

Reads from LiveResourceRepository filtered by 'scheduling' capability
instead of event-specific eventRepo. Shape parity via events_view
(mig 00156 drop-in). No behavior change."
```

---

## Task 11: Move `HomeCoordinator` to `Features/Home/`

**Files:**
- Move: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/HomeCoordinator.swift` → `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift`

- [ ] **Step 1: Move file**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/HomeCoordinator.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift
```

- [ ] **Step 2: Polymorphize the data source inside the coordinator**

Same substitution as Task 10 — `eventRepo` → `resourceRepo`, `Event` → `Resource` polymorphic with capability filter.

If `HomeCoordinator` exposes `upcomingEvents: [Event]`, rename to `upcomingResources: [Resource]` (or generalize) and update callsites in `HomeView` + `HomeTab` accordingly.

- [ ] **Step 3: Update RootShell.rebuildCoordinators**

The `HomeCoordinator(/* fill from MainTabView pattern */)` placeholder in Task 9's RootShell now needs the real constructor args. Open the moved coordinator, look at its init, and fill the call site in RootShell.

- [ ] **Step 4: Build + test + smoke**

```bash
make -C ios project
make -C ios build
make -C ios test 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift
git commit -m "refactor(home): move HomeCoordinator to Features/Home, polymorphize"
```

---

## Task 12: Move + generalize Event coordinators

**Files (5 moves):**
- `Features/Events/Coordinator/EventCreationCoordinator.swift` → `Features/Create/ResourceCreationCoordinator.swift`
- `Features/Events/Coordinator/EventEditCoordinator.swift` → `Features/Resources/Edit/ResourceEditCoordinator.swift`
- `Features/Events/Coordinator/EventLedgerCoordinator.swift` → `Features/Resources/Money/ResourceLedgerCoordinator.swift`
- `Features/Events/Coordinator/EventRulesCoordinator.swift` → `Features/Rules/ResourceRulesCoordinator.swift`
- `Features/Events/Coordinator/CheckInScannerCoordinator.swift` → `Features/Resources/CheckIn/CheckInScannerCoordinator.swift`

For each move:

- [ ] **Step 1: Move with git mv + create destination dir if needed**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Create
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/EventCreationCoordinator.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Create/ResourceCreationCoordinator.swift
# ...repeat for the other 4
```

- [ ] **Step 2: Rename the type inside the file**

For each moved coordinator, open and rename the type:

```swift
// EventCreationCoordinator → ResourceCreationCoordinator
// EventEditCoordinator → ResourceEditCoordinator
// EventLedgerCoordinator → ResourceLedgerCoordinator
// EventRulesCoordinator → ResourceRulesCoordinator
```

`CheckInScannerCoordinator` keeps its name (already capability-scoped).

- [ ] **Step 3: Find + update callers**

```bash
grep -rn "EventCreationCoordinator\|EventEditCoordinator\|EventLedgerCoordinator\|EventRulesCoordinator" \
  ios/ --include="*.swift" | grep -v ".build\|DerivedData"
```

Expected: a handful of callsites in `MainTabView`, `EventDetailHost`, etc. Rename each occurrence to the new type name. Use rg + sed if there are many:

```bash
rg -l "EventCreationCoordinator" ios/ --type swift | xargs sed -i '' 's/EventCreationCoordinator/ResourceCreationCoordinator/g'
# Repeat per coordinator
```

Verify after:

```bash
grep -rn "EventCreationCoordinator\|EventEditCoordinator\|EventLedgerCoordinator\|EventRulesCoordinator" \
  ios/ --include="*.swift" | grep -v ".build"
```

Expected: zero matches.

- [ ] **Step 4: Build + test**

```bash
make -C ios project
make -C ios build
make -C ios test 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 5: Commit (one commit per coordinator for cleaner diff)**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Create/ResourceCreationCoordinator.swift
git commit -m "refactor(create): rename EventCreationCoordinator → ResourceCreationCoordinator

Generalized name. No behavior change yet (event-only paths still
exclusive). Pass 3 of the wizard work extends to other resource types."
```

Repeat for the other 4 coordinators.

---

## Task 13: Promote Event subviews to `RuulUI/Patterns/Resource/`

**Files (5 moves):**
- `Features/Events/Subviews/EventCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/ResourceHeroCard.swift`
- `Features/Events/Subviews/EventRSVPStateView.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/RSVPStateView.swift`
- `Features/Events/Subviews/EventLocationCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/LocationCard.swift`
- `Features/Events/Subviews/RecurrenceOptionsCard.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/RecurrenceOptionsCard.swift`
- `Features/Events/Subviews/LocationAutocompletePicker.swift` → `Packages/RuulUI/Sources/RuulUI/Patterns/Resource/LocationAutocompletePicker.swift`

- [ ] **Step 1: Check RuulUI Package.swift for Patterns/Resource path**

```bash
cat ios/Packages/RuulUI/Package.swift
ls ios/Packages/RuulUI/Sources/RuulUI/Patterns/ 2>/dev/null
```

Patterns folder exists (verified at spec time). Create `Resource/` subfolder:

```bash
mkdir -p ios/Packages/RuulUI/Sources/RuulUI/Patterns/Resource
```

- [ ] **Step 2: Move EventCard → ResourceHeroCard**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Subviews/EventCard.swift \
       ios/Packages/RuulUI/Sources/RuulUI/Patterns/Resource/ResourceHeroCard.swift
```

Open the moved file. Rename type `EventCard` → `ResourceHeroCard`. Generalize the input from `event: Event` to `resource: Resource` + a small `HeroCardProps` view-model that the call site builds (so the card itself doesn't reach into event metadata directly):

```swift
public struct HeroCardProps: Sendable {
    public let title: String
    public let dateLabel: String?
    public let participantsCount: Int?
    public let coverImageURL: URL?
    public let chrome: ResourceTypeChrome

    public init(
        title: String,
        dateLabel: String?,
        participantsCount: Int?,
        coverImageURL: URL?,
        chrome: ResourceTypeChrome
    ) {
        self.title = title
        self.dateLabel = dateLabel
        self.participantsCount = participantsCount
        self.coverImageURL = coverImageURL
        self.chrome = chrome
    }
}

public struct ResourceHeroCard: View {
    let props: HeroCardProps
    public init(_ props: HeroCardProps) { self.props = props }
    public var body: some View { /* ...existing rendering, reading from props... */ }
}
```

`Resource` is in `RuulCore`. Since RuulUI must depend on RuulCore for this, update `Packages/RuulUI/Package.swift` to declare a dependency on RuulCore:

```swift
// In RuulUI/Package.swift dependencies:
.package(path: "../RuulCore"),

// In target dependencies:
.product(name: "RuulCore", package: "RuulCore"),
```

Verify the dependency direction is already one-way; if RuulCore depends on RuulUI, that's a cycle — back out the direction (props pattern keeps the card RuulCore-agnostic if you prefer to avoid the dependency).

Recommended: use the **props pattern** (no RuulCore dependency in RuulUI). Callers build the props, the card is pure UI.

- [ ] **Step 3: Move the other 4 subviews**

Apply the same pattern:
- `EventRSVPStateView` → `RSVPStateView` — takes a small `RSVPStateProps` struct (counts: going / maybe / no / pending, viewer status)
- `EventLocationCard` → `LocationCard` — takes lat/lng + label
- `RecurrenceOptionsCard` → `RecurrenceOptionsCard` — already capability-scoped, just move
- `LocationAutocompletePicker` → `LocationAutocompletePicker` — already capability-scoped

For each: rename type if needed, extract a Props struct so RuulUI doesn't need RuulCore.

- [ ] **Step 4: Update callsites**

```bash
grep -rln "EventCard\|EventRSVPStateView\|EventLocationCard" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
```

For each callsite:
1. Change the type name: `EventCard(...)` → `ResourceHeroCard(.init(...))`
2. Build the Props struct from the existing `Event` instance.

If many callsites duplicate the Props construction, add a small helper `extension Event { var heroCardProps: HeroCardProps { ... } }` in `RuulFeatures/Resources/Adapters/` so each callsite remains a one-liner.

- [ ] **Step 5: Build + test + smoke**

```bash
make -C ios project
make -C ios build
make -C ios test 2>&1 | tail -10
```

Expected: green. Visually smoke in simulator that EventCard rendering is unchanged.

- [ ] **Step 6: Commit**

```bash
git add -A ios/Packages/RuulUI/ ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
git commit -m "refactor(ui): promote event subviews to RuulUI/Patterns/Resource

Five capability-scoped components moved from Features/Events/Subviews
to RuulUI/Patterns/Resource with Props-based APIs. RuulUI stays
RuulCore-free. Callsites updated."
```

---

## Task 14: Extract `EventInteractor` protocol from `EventDetailCoordinator`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/EventDetailCoordinator.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EventInteractor.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

This task continues the work started in spec 2026-05-11 (universal detail migration).

- [ ] **Step 1: Define the protocol**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EventInteractor.swift`:

```swift
import Foundation
import RuulCore
import SwiftUI

/// Event-specific interaction contract for `UniversalResourceDetailView`.
/// Pre-Pass-1, RSVP / check-in / host actions were owned by
/// `EventDetailCoordinator` which doubled as the host view's model.
/// Pass 1 splits the contract from the concrete coordinator so the
/// universal detail view can inject any conformer via `@Environment`.
///
/// Spec 2026-05-11 originally planned this; Pass 1 completes it.
@MainActor
public protocol EventInteractor: AnyObject {
    var rsvpIntent: RSVPIntent? { get }
    func setRSVP(_ status: RSVPStatus) async throws
    func checkIn(memberID: UUID) async throws
    func closeEvent() async throws
    func cancelEvent() async throws
    func remindAttendees() async throws
    var canHost: Bool { get }
}

private struct EventInteractorEnvironmentKey: EnvironmentKey {
    static let defaultValue: (any EventInteractor)? = nil
}

public extension EnvironmentValues {
    var eventInteractor: (any EventInteractor)? {
        get { self[EventInteractorEnvironmentKey.self] }
        set { self[EventInteractorEnvironmentKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Conform `EventDetailCoordinator`**

In `EventDetailCoordinator.swift`, add an extension at the bottom:

```swift
extension EventDetailCoordinator: EventInteractor {
    // The protocol members already exist on the concrete class — this
    // extension just declares conformance. If method shapes don't match
    // exactly, add thin wrappers here to bridge the protocol vs concrete API.
}
```

If a method shape mismatches (e.g. protocol says `setRSVP(_:)` but coordinator has `submitRSVP(status:)`), add a wrapper:

```swift
extension EventDetailCoordinator: EventInteractor {
    public func setRSVP(_ status: RSVPStatus) async throws {
        try await submitRSVP(status: status)
    }
}
```

- [ ] **Step 3: Inject in `UniversalResourceDetailView`**

In `UniversalResourceDetailView.swift`, replace direct `EventDetailCoordinator` references with `@Environment(\.eventInteractor)`:

```swift
@Environment(\.eventInteractor) private var eventInteractor

// Section guards:
if let interactor = eventInteractor, resource.resourceType == .event {
    HostActionsSectionView(interactor: interactor, resource: resource)
}
```

Sections that already accept an `EventDetailCoordinator` param change to accept `any EventInteractor`.

- [ ] **Step 4: Build + test**

```bash
make -C ios project
make -C ios build
make -C ios test 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EventInteractor.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/EventDetailCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
git commit -m "feat(detail): extract EventInteractor protocol + @Environment injection

Completes spec 2026-05-11 — UniversalResourceDetailView no longer
references EventDetailCoordinator concretely. Conformance lives on
the coordinator; injection via SwiftUI environment. Sets up Task 17
deletion of EventDetailHost."
```

---

## Task 15: Route detail navigation through `RootRouter.openResource`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift`

- [ ] **Step 1: Add `openResource(id:)` to RootRouter**

In `RootRouter.swift`:

```swift
/// Polymorphic detail entry: pushes a `RootRoute.eventDetail` for now
/// (Pass 1 keeps the route name event-shaped for compat with
/// EventDeepLink). Future passes can fork on resource_type.
public func openResource(id: UUID) {
    present(.eventDetail(id))
}
```

And update its corresponding test in `RootRouterTests.swift`:

```swift
@Test("openResource(id:) pushes eventDetail route")
func openResource() {
    let (router, state) = makeRouter()
    let id = UUID()
    router.openResource(id: id)
    #expect(state.activeRoutes == [.eventDetail(id)])
}
```

- [ ] **Step 2: Update RootShellSheets eventDetail branch**

In `RootShellSheets.swift`, replace the `.sheet(item: ...)` for `eventDetail` so it presents `UniversalResourceDetailView` (NOT `EventDetailHost`):

```swift
.sheet(item: bindingForEventDetail) { eventID in
    UniversalResourceDetailView(resourceID: eventID)
        .environment(app)
        // EventInteractor injection happens INSIDE UniversalResourceDetailView
        // via a small adapter view that constructs EventDetailCoordinator
        // for event-typed resources.
}

private var bindingForEventDetail: Binding<UUID?> {
    Binding(
        get: {
            router.state.activeRoutes.compactMap {
                if case .eventDetail(let id) = $0 { return id } else { return nil }
            }.last
        },
        set: { newValue in
            if newValue == nil {
                // Find and remove any eventDetail route
                router.state.activeRoutes
                    .filter { if case .eventDetail = $0 { return true } else { return false } }
                    .forEach { _ in router.dismissTop() }
            }
        }
    )
}
```

- [ ] **Step 3: Build + smoke test (with flag ON)**

```bash
make -C ios project
make -C ios build
```

Manually:
- Open the app with `useNewShell = true`
- Tap an event in Home → `UniversalResourceDetailView` opens
- Verify RSVP / check-in / host actions work (these come from the `EventInteractor` injection — fail here means Task 14's environment wiring is incomplete; fix that, not this task)

- [ ] **Step 4: Run tests**

```bash
make -C ios test 2>&1 | grep -E "RootRouter|PASS|FAIL" | head -15
```

Expected: PASS — new `openResource` test green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift \
        ios/TandasTests/Shell/RootRouterTests.swift
git commit -m "feat(shell): route resource detail through UniversalResourceDetailView

RootRouter.openResource(id:) → eventDetail route → sheet presents
UniversalResourceDetailView (not EventDetailHost). EventInteractor
injection from Task 14 handles the event-specific behavior.
EventDetailHost still exists but is no longer reached from RootShell.
Task 17 deletes it."
```

---

## Task 16: Verify EventDetailHost is no longer reachable from RootShell

**Files:**
- (none — verification step)

- [ ] **Step 1: Search for `EventDetailHost` references inside the new Shell**

```bash
grep -rn "EventDetailHost" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/ \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/
```

Expected: zero matches. `EventDetailHost` should only appear in legacy `Features/Events/` paths (still alive because the flag-off branch uses it).

- [ ] **Step 2: Smoke RSVP / check-in / host actions in new shell**

In simulator with `useNewShell = true`:
1. Tap an upcoming event in Home → detail opens
2. Tap "Voy" / "No voy" / "Tal vez" — verify RSVP persists (refresh, check the chip)
3. As host, tap "Check-in" — verify scanner opens via `RootRoute.scanner` branch
4. Tap "Cerrar evento" — verify close confirmation flow

Any of these failing means an `EventInteractor` method is unimplemented or a route wiring is missing. Fix before continuing.

- [ ] **Step 3: Commit no-op marker (optional, for diff clarity)**

```bash
git commit --allow-empty -m "chore(verify): EventDetailHost not reachable from new shell

Manual smoke green: RSVP, check-in, host actions all work via
UniversalResourceDetailView + EventInteractor. EventDetailHost is
now dead code in the new-shell branch; Task 17 deletes it after
the flag flip."
```

---

## Task 17: Flip `useNewShell` default to true

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`

- [ ] **Step 1: Flip the flag**

In `AppState.swift`, change:

```swift
public var useNewShell: Bool = false
```

to:

```swift
public var useNewShell: Bool = true
```

- [ ] **Step 2: Run full test suite**

```bash
make -C ios test 2>&1 | tail -20
```

Expected: green. Any failure here means a test was implicitly depending on the legacy MainTabView surface; treat as a Pass 1 regression and fix.

- [ ] **Step 3: Device smoke (not just simulator)**

If a physical iOS 26 device is available, build and run on it:

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS,name=<your-device-name>' build
```

Then deploy via Xcode and run through:
- Cold start → Home tab loads
- Switch group via header → coordinators rebuild
- Push notification with EventDeepLink → opens detail
- Create event flow end-to-end
- Vote / fine flow end-to-end
- Real Liquid Glass material visible on tab bar minimization

If no device available, document the limitation in the PR description.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "feat(shell): flip useNewShell to true — RootShell is now the default

Manual smoke + device test green (see PR description for device run
notes if applicable). Legacy MainTabView is now unreachable in normal
operation; Task 18+ deletes it."
```

---

## Task 18: Delete legacy MainTabView, HomeView, EventDetailHost, CreateEventView, EditEventView, MainTabStubs

**Files:**
- Delete: 6 files in `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/`

- [ ] **Step 1: Verify no remaining references in non-Events code**

```bash
for type in MainTabView EventDetailHost CreateEventView EditEventView; do
  echo "=== $type ==="
  grep -rn "$type" ios/ --include="*.swift" \
    | grep -v "Features/Events/" \
    | grep -v ".build\|DerivedData" \
    | head -5
done
```

Expected: only references are inside `Features/Events/` itself (intra-folder), plus the now-deleted reference in `AuthGate.swift` (line 54 should already be `if app.useNewShell { RootShell() } else { MainTabView() }` — change to just `RootShell()` in Step 2).

- [ ] **Step 2: Remove the conditional in AuthGate**

In `ios/Tandas/Shell/AuthGate.swift`, replace:

```swift
            } else {
                if app.useNewShell {
                    RootShell()
                } else {
                    MainTabView()
                }
            }
```

with:

```swift
            } else {
                RootShell()
            }
```

And the import of `MainTabView` (if any) can be cleaned up.

- [ ] **Step 3: Delete the 6 files**

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/MainTabView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/HomeView.swift   # if not already deleted by Task 10's move
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/EventDetailHost.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/CreateEventView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/EditEventView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/MainTabStubs.swift
```

- [ ] **Step 4: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -15
make -C ios test 2>&1 | tail -15
```

Expected: green. If `EventDetailCoordinator` still exists in `Features/Events/Coordinator/` and references the deleted views, the EventInteractor extraction (Task 14) hasn't fully decoupled. Resolve by moving `EventDetailCoordinator` to `Features/Resources/Detail/Adapters/EventDetailCoordinator.swift` (no rename — it stays the concrete coordinator that conforms to `EventInteractor`).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(shell): delete legacy MainTabView + HomeView + EventDetailHost et al

6 files removed from Features/Events/Views/. AuthGate now always
RootShell — feature flag served its purpose, removed.

  - MainTabView.swift                (1619 L → 0)
  - EventDetailHost.swift             (438 L → 0)
  - CreateEventView.swift             (313 L → 0)
  - EditEventView.swift               (varies)
  - MainTabStubs.swift                (varies)
  - HomeView.swift                    (deleted in Task 10's move)"
```

---

## Task 19: Delete remaining `Features/Events/` contents

**Files:**
- Delete: all files remaining in `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/`

- [ ] **Step 1: Inventory remaining files**

```bash
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events -name "*.swift"
```

Expected remainders (after Tasks 10–14 moved things):
- `Coordinator/EventDetailCoordinator.swift` — needs decision: move to Adapters or keep here briefly
- `Coordinator/CheckInScannerCoordinator.swift` — moved in Task 12; if not yet, do now
- `Sheets/*.swift` (10 sheets) — distribute to capability-scoped folders
- `Subviews/EventCard.swift` etc. — already moved in Task 13; if any subviews remain (e.g. small ones not in Task 13's list), move them too

- [ ] **Step 2: Move sheets to capability-scoped homes**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Sheets/{HostActions,Money,RSVP,Sharing}

# Mapping:
git mv .../Events/Sheets/AddEventRuleSheet.swift          .../Resources/Sheets/HostActions/AddEventRuleSheet.swift
git mv .../Events/Sheets/AddLedgerEntrySheet.swift        .../Resources/Sheets/Money/AddLedgerEntrySheet.swift
git mv .../Events/Sheets/CancelAttendanceSheet.swift      .../Resources/Sheets/RSVP/CancelAttendanceSheet.swift
git mv .../Events/Sheets/CancelEventSheet.swift           .../Resources/Sheets/HostActions/CancelEventSheet.swift
git mv .../Events/Sheets/CloseEventSheet.swift            .../Resources/Sheets/HostActions/CloseEventSheet.swift
git mv .../Events/Sheets/EventLedgerSheet.swift           .../Resources/Sheets/Money/EventLedgerSheet.swift
git mv .../Events/Sheets/EventRulesSheet.swift            .../Resources/Sheets/HostActions/EventRulesSheet.swift
git mv .../Events/Sheets/MemberQRSheet.swift              .../Resources/Sheets/Sharing/MemberQRSheet.swift
git mv .../Events/Sheets/RemindAttendeesSheet.swift       .../Resources/Sheets/RSVP/RemindAttendeesSheet.swift
git mv .../Events/Sheets/ShareEventSheet.swift            .../Resources/Sheets/Sharing/ShareEventSheet.swift
```

(Path prefix abbreviated for readability — use the full `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/...` path.)

- [ ] **Step 3: Move EventDetailCoordinator**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Coordinator/EventDetailCoordinator.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailCoordinator.swift
```

The type name stays `EventDetailCoordinator` (it's the concrete `EventInteractor` conformer for event-typed resources — meaningful name).

- [ ] **Step 4: Move PastEventsView and CheckInScannerView if not already**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/{Past,CheckIn}
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/PastEventsView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Past/PastResourcesView.swift
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/Views/CheckInScannerView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/CheckIn/CheckInScannerView.swift
```

Rename type `PastEventsView` → `PastResourcesView` inside the moved file. Update callsites:

```bash
grep -rln "PastEventsView" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
```

For each, swap the type.

- [ ] **Step 5: Verify Events folder is empty**

```bash
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events -name "*.swift"
```

Expected: zero files.

- [ ] **Step 6: Remove the empty folder**

```bash
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events/{Coordinator,Sheets,Subviews,Views} 2>/dev/null
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events
```

- [ ] **Step 7: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -15
make -C ios test 2>&1 | tail -15
```

Expected: green. If `make -C ios project` fails because xcodegen can't find a path, check `project.yml` for any explicit references to `Features/Events/` and remove them.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(events): delete Features/Events/ — moves complete

Sheets distributed to Features/Resources/Sheets/<capability>/.
EventDetailCoordinator → Features/Resources/Detail/Adapters/.
PastEventsView → PastResourcesView in Features/Resources/Past/.
CheckInScannerView → Features/Resources/CheckIn/.

Features/Events/ folder is removed. Pass 1 deletion complete."
```

---

## Task 20: Mark `GroupTabView` as deprecated (Pass 2 deletes)

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupTabView.swift`

- [ ] **Step 1: Annotate**

At the top of the `GroupTabView` type declaration, add:

```swift
@available(*, deprecated, message: "Pass 2 deletes this — GroupTab will dissolve into Inbox + Activity + GroupInfoSheet. Don't add new dependencies.")
public struct GroupTabView: View {
    // ...existing body
}
```

- [ ] **Step 2: Build**

```bash
make -C ios build 2>&1 | grep -i "deprecated" | head -5
```

Expected: build succeeds with deprecation warnings at GroupTabView callsites (one in `GroupTab.swift` from Task 8). This is OK — the warning makes Pass 2's intent visible. Suppress the warning at the single callsite inside `GroupTab.swift` with `@available` or `@nonobjc` doesn't apply here; just leave it as a visible warning until Pass 2.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupTabView.swift
git commit -m "chore(group): mark GroupTabView deprecated for Pass 2

The Group tab dissolves in Pass 2 — sub-tabs distribute to Inbox,
Activity, and GroupInfoSheet per AppShell.md. Annotation makes Pass 2
work obvious; suppress the warning at the single callsite inside
GroupTab.swift until then."
```

---

## Task 21: Final metrics + project regen + green CI

**Files:**
- (none — verification + project regen)

- [ ] **Step 1: Run all metric queries from spec**

```bash
echo "=== Files > 500 L in Features/ ==="
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features -name "*.swift" \
  | xargs wc -l | awk '$1 > 500 {print}' | sort -rn

echo "=== Files > 250 L in Features/ ==="
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features -name "*.swift" \
  | xargs wc -l | awk '$1 > 250 {print}' | sort -rn | head -20

echo "=== switch resource.resourceType in Views ==="
grep -rn "switch.*resource\.resourceType\|switch.*resourceType" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ \
  | grep -v "Tests\|//" | wc -l

echo "=== Features/Events/ existence ==="
test -d ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Events && echo "EXISTS (bad)" || echo "removed (good)"

echo "=== Detail screens for Resource ==="
grep -rln "struct UniversalResourceDetailView\|struct EventDetailHost\|struct EventDetailView" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/
```

Expected (Pass 1 targets):
- Files > 500 L: GroupTabView (deprecated, dies in Pass 2) + a couple more from non-Events areas (acceptable)
- `switch resource.resourceType` in Views: 0
- `Features/Events/` directory: removed
- Detail screens: only `UniversalResourceDetailView` (1)

- [ ] **Step 2: Diff size check**

```bash
git diff main --stat | tail -3
```

Expected: net `~-2500 to -3500` line reduction (some of the bulk moved to RuulUI so the absolute number lands lower than the spec's target of -3000 to -4000; the full -3000 to -4000 is reached after Pass 2 deletions).

- [ ] **Step 3: Full test suite + project regen**

```bash
make -C ios project
make -C ios test 2>&1 | tail -20
```

Expected: green. All Swift Testing suites pass. No xcodebuild errors.

- [ ] **Step 4: Commit final marker**

```bash
git commit --allow-empty -m "chore(pass1): Pass 1 metrics verified, ready to merge

Files >500L (excl Pass-2-deprecated GroupTabView): N (target: 0)
switch-on-resourceType in Views: 0 (target: 0)
Features/Events/ folder: removed
Detail screens for Resource: 1 (UniversalResourceDetailView)
Net diff: see git diff main --stat

Pass 2 (AppShell canonical) starts next."
```

- [ ] **Step 5: Push + open PR**

```bash
git push -u origin pass1/extirpate-events-vertical
gh pr create --title "Pass 1: extirpate Events vertical from frontend" --body "$(cat <<'EOF'
## Summary
- Replace 1619L `Features/Events/Views/MainTabView.swift` with `Features/Shell/` (RootShell + RootShellState + RootRouter + RootShellSheets, all <250L)
- Delete `Features/Events/` folder entirely — Sheets, Subviews, Coordinators, Views all moved to capability-scoped locations
- Single `UniversalResourceDetailView` for resource detail; `EventInteractor` protocol injected via SwiftUI `@Environment`
- New `ResourceTypeChrome` eliminates 20 scattered `switch resource.resourceType` sites in views
- Mark `GroupTabView` deprecated (Pass 2 deletes)

Spec: `docs/superpowers/specs/2026-05-14-frontend-remodel-design.md`
Plan: `docs/superpowers/plans/2026-05-14-frontend-remodel-pass1.md`

## Test plan
- [ ] `make -C ios test` green
- [ ] Cold-start app, verify Home tab renders
- [ ] Switch groups via header — coordinators rebuild
- [ ] Tap event → UniversalResourceDetailView opens
- [ ] RSVP / check-in / host actions work via EventInteractor
- [ ] Push notification with EventDeepLink routes to detail
- [ ] Create event flow end-to-end
- [ ] Vote / fine flow end-to-end
- [ ] (if device available) Real Liquid Glass material on tab bar minimization

🤖 Generated with [claude-flow](https://github.com/ruvnet/claude-flow)
EOF
)"
```

Expected: PR URL printed. Review against the spec's metrics table.

---

## Self-review notes

**Spec coverage:** Every section of the spec (ResourceTypeChrome, Shell decomposition with file lines, file moves table, capability chrome registry, EventInteractor injection, feature flag, DoD bullets, metrics) maps to at least one task here. Pass 2 and Pass 3 work explicitly out of scope.

**Placeholders:** Exactly one intentional placeholder remains — `RootShell.rebuildCoordinators()` shows `HomeCoordinator(/* fill from MainTabView pattern */)` because the constructor args depend on AppState shape that may evolve before execution. The instruction "open MainTabView.rebuildCoordinators and copy the body" is concrete enough for the executor.

**Type consistency:** `EventInteractor` (Task 14) is consumed in `UniversalResourceDetailView` and `RootShellSheets` (Task 15). `RootRoute.eventDetail(UUID)` is consistent across Tasks 5, 6, 15. `ResourceTypeChrome.resolve(_:)` signature is consistent in Tasks 3 and 4.

**Out of scope explicitly:** any iOS 26 polish (`.glassEffect()`, `ScrollTransition`, `.contentMargins`) — those are Pass 3. Any tab inventory change — Pass 2. Any SwiftLint custom rules — Pass 3.

---

## References

- Spec: `docs/superpowers/specs/2026-05-14-frontend-remodel-design.md`
- Constitución: `Plans/Active/Constitution.md`
- AppShell canonical: `Plans/Active/AppShell.md`
- Design principles: `docs/DesignPrinciples.md`
- Prior spec (partial): `docs/superpowers/specs/2026-05-11-universal-event-detail-migration-design.md`
