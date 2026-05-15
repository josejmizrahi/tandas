# UniversalResourceDetailView v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current 35-file / 5700-line `Features/Resources/Detail/` implementation with an Apple Invites-inspired layout: cover hero + single CTA + native NavigationStack chrome + section order by user question.

**Architecture:** Pure-logic resolver layer in `RuulCore/Capabilities/` (PrimaryAction + QuickFacts + SecondaryActions, fully unit-testable) + new view layer in `RuulFeatures` (ResourceCoverHero, ResourceQuickFactsView, ResourcePrimaryCTA, ResourceDetailPanel). Cutover via `AppState.useNewDetail` feature flag (mirrors Pass 1 `useNewShell` pattern). Old code stays alive as `UniversalResourceDetailViewLegacy` until flag flip + delete sweep.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI iOS 26, `@Observable`, MeshGradient (iOS 18+), Swift Testing.

**Branch:** `detail-redesign/v2` (worktree).

**Test command:** `make -C ios test`. Baseline: 182+ tests / 37+ suites green (post Pass 3 cleanup).

**Spec:** `docs/superpowers/specs/2026-05-14-universal-resource-detail-redesign.md`

---

## Conventions

- `make -C ios project` after adding/removing files (xcodegen)
- `make -C ios build` for fast compile checks (~10s)
- `make -C ios test` full suite (~5-10 min); 600000ms timeout on Bash invocations
- Worktree path: `/Users/jj/code/tandas/.claude/worktrees/detail-redesign+v2`
- Test file pattern: `ios/TandasTests/<Subsystem>/<TypeUnderTest>Tests.swift`, `import Testing`, `@testable import Tandas`
- Commit messages: `feat(scope): subject` style; no Co-Authored-By; no emojis

---

## File structure (target post-cutover)

```
Features/Resources/Detail/
  UniversalResourceDetailView.swift          (~180L) — NEW orchestrator
  ResourceDetailPanel.swift                   (~60L)  — NEW rounded panel wrapper
  ResourceCoverHero.swift                     (~150L) — NEW cover + parallax + overlay
  ResourceQuickFactsView.swift                (~80L)  — NEW horizontal pills
  ResourcePrimaryCTA.swift                    (~80L)  — RENAMED from DetailStickyFooterView
  ResourceDetailContext.swift                 (existing, light edits)
  EventInteractor.swift                       (existing)
  EventDetailPresenter.swift                  (existing)
  EnableCapabilitySheet.swift                 (existing)
  CapabilitySection.swift                     (existing)
  Sections/
    DescriptionSectionView.swift              (existing)
    RSVPSectionView.swift                     (existing)
    CheckInSectionView.swift                  (existing)
    MoneySectionView.swift                    (existing)
    RulesSectionView.swift                    (existing)
    ActivitySectionView.swift                 (existing)
    HostActionsSectionView.swift              (existing — repurposed as menu source)
    RotationSectionView.swift                 (existing)
    SettlementSheet.swift                     (existing)
    SettingsSectionView.swift                 (~80L)  — NEW collapsed accordion
  Adapters/
    EventDetailHost.swift                     (~120L) — slimmed
    EventDetailBootstrap.swift                (~80L)  — NEW
    EventDetailSheets.swift                   (~200L) — NEW ViewModifier
    EventDetailCoordinator.swift              (existing, untouched)
    EditEventView.swift                       (existing)
  Sheets/AttendeesListSheet.swift             (existing)
  Subviews/RSVPAvatarStrip.swift              (existing)
  PreviewSupport/MockEventInteractor.swift    (existing)

# DELETED at cutover (Task 16):
- UniversalResourceDetailViewLegacy.swift     (renamed-and-then-deleted)
- Zones/DetailTopNavView.swift
- Zones/DetailHeaderView.swift
- Zones/EventHeroTitleBlock.swift
- Zones/DetailPrimaryActions.swift
- Zones/DetailActionsBar.swift
- Zones/DetailCoverView.swift
- Zones/DetailStickyFooterView.swift           (renamed to ResourcePrimaryCTA)
- Zones/DetailAttentionView.swift              (folded inline as NeedsAttention card)
- Layouts/EventInvitesContent.swift            (review, likely delete)

# Existing in RuulCore that grow:
ios/Packages/RuulCore/Sources/RuulCore/Capabilities/
  PrimaryAction.swift                         (~40L)  — NEW
  SecondaryAction.swift                       (~40L)  — NEW
  QuickFact.swift                             (~30L)  — NEW
  CapabilityResolver+PrimaryAction.swift      (~120L) — NEW (extension)
  CapabilityResolver+QuickFacts.swift         (~80L)  — NEW (extension)
  CapabilityResolver+SecondaryActions.swift   (~80L)  — NEW (extension)
  CapabilityResolver+CoverSubtitle.swift      (~50L)  — NEW (extension)

# Tests:
ios/TandasTests/Capabilities/
  CapabilityResolver+PrimaryActionTests.swift (~150L) — NEW (~12 cases)
  CapabilityResolver+QuickFactsTests.swift    (~80L)  — NEW
  CapabilityResolver+SecondaryActionsTests.swift (~80L) — NEW
```

---

## Task 1: Worktree + baseline + `useNewDetail` flag

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift` (add flag near `useNewShell`)

- [ ] **Step 1: Create worktree from latest main**

```bash
cd /Users/jj/code/tandas
git worktree add .claude/worktrees/detail-redesign+v2 -b detail-redesign/v2 origin/main
cd .claude/worktrees/detail-redesign+v2
```

- [ ] **Step 2: Verify clean baseline**

```bash
git status && git log --oneline -3
make -C ios test 2>&1 | tail -5
```

Expected: clean tree, baseline tests green.

- [ ] **Step 3: Add `useNewDetail` flag to AppState**

In `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`, find the `useNewShell` property (around line 80 post-Pass-1) and add immediately after:

```swift
    /// Detail-redesign A/B flag. Default `false` until Task 15 flip
    /// after manual smoke. When true, RootShellSheets eventDetail
    /// branch presents the new UniversalResourceDetailView (cover hero
    /// + sticky CTA + nav-bar chrome). When false, falls back to
    /// UniversalResourceDetailViewLegacy (the pre-redesign layout).
    public var useNewDetail: Bool = false
```

- [ ] **Step 4: Build + commit baseline marker**

```bash
make -C ios build 2>&1 | tail -3
git add ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "chore(detail-v2): start branch + add useNewDetail flag

Worktree at .claude/worktrees/detail-redesign+v2 from origin/main.
useNewDetail defaults to false until Task 15 cutover.
Spec: docs/superpowers/specs/2026-05-14-universal-resource-detail-redesign.md"
```

---

## Task 2: `PrimaryAction` + `SecondaryAction` + `QuickFact` types

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/PrimaryAction.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/SecondaryAction.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/QuickFact.swift`

- [ ] **Step 1: Write `PrimaryAction.swift`**

```swift
import Foundation

/// Single primary CTA for a resource detail screen, decided by
/// `CapabilityResolver.primaryAction(...)`. Drives the sticky footer
/// in `UniversalResourceDetailView`.
public struct PrimaryAction: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case standard       // accent fill
        case prominent      // larger, more visual weight
        case destructive    // red tint
    }

    /// Logical kind of action — view dispatches based on this to existing
    /// presenter callbacks. Adding a new resource type means adding a
    /// case here + a branch in the resolver + a dispatch in the view.
    public enum Kind: Sendable, Hashable {
        case rsvpConfirm        // event + viewer hasn't RSVP'd
        case rsvpCancel         // event + viewer has RSVP'd "going"
        case viewHostActions    // event + viewer is host (opens action sheet)
        case openContribute     // fund (placeholder — Phase 2 wires)
        case openBooking        // asset (placeholder — Phase 2 wires)
        case viewClosed         // event closed (or readonly)
        case none               // no CTA — caller hides the footer
    }

    public let label: String
    public let symbol: String?
    public let style: Style
    public let kind: Kind

    public init(label: String, symbol: String?, style: Style, kind: Kind) {
        self.label = label
        self.symbol = symbol
        self.style = style
        self.kind = kind
    }

    /// Sentinel for the "no CTA" case. Caller can `if action.kind == .none`
    /// or use this constant directly.
    public static let none = PrimaryAction(
        label: "",
        symbol: nil,
        style: .standard,
        kind: .none
    )
}
```

- [ ] **Step 2: Write `SecondaryAction.swift`**

```swift
import Foundation

/// Item in the nav bar `⋯` menu, decided by
/// `CapabilityResolver.secondaryActions(...)`. Order in the returned
/// array IS the menu order; sections are visual groups (separators
/// drawn between consecutive items with different `section` values).
public struct SecondaryAction: Sendable, Hashable, Identifiable {
    public enum Section: Sendable, Hashable {
        case primary      // edit, share, calendar
        case host         // remind, close, cancel
        case money        // ledger, manual fine
        case governance   // rules, capabilities
        case danger       // archive
    }

    public enum Kind: Sendable, Hashable {
        case editDetails
        case addToCalendar
        case share
        case generateWalletPass
        case remindAttendees
        case closeEvent
        case cancelEvent
        case openLedger
        case issueManualFine
        case openRules
        case enableCapability
        case archive
    }

    public var id: Kind { kind }

    public let label: String
    public let symbol: String
    public let section: Section
    public let kind: Kind
    public let isDestructive: Bool

    public init(
        label: String,
        symbol: String,
        section: Section,
        kind: Kind,
        isDestructive: Bool = false
    ) {
        self.label = label
        self.symbol = symbol
        self.section = section
        self.kind = kind
        self.isDestructive = isDestructive
    }
}
```

- [ ] **Step 3: Write `QuickFact.swift`**

```swift
import Foundation

/// Horizontal-pill fact in `ResourceQuickFactsView`. Polymorphic
/// across resource types via `CapabilityResolver.quickFacts(...)`.
public struct QuickFact: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case date           // event when, fund last activity
        case time           // event time of day
        case location       // event/asset location
        case capacity       // event "8/12"
        case balance        // fund balance
        case progress       // fund "$x of $y"
        case status         // asset/right availability
        case host           // event host name
        case custodian      // asset custodian
    }

    public let id: String
    public let kind: Kind
    public let symbol: String   // SF Symbol
    public let label: String    // display string (already localized/formatted)

    public init(id: String, kind: Kind, symbol: String, label: String) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.label = label
    }
}
```

- [ ] **Step 4: Build**

```bash
make -C ios project
make -C ios build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/PrimaryAction.swift \
        ios/Packages/RuulCore/Sources/RuulCore/Capabilities/SecondaryAction.swift \
        ios/Packages/RuulCore/Sources/RuulCore/Capabilities/QuickFact.swift
git commit -m "feat(core): PrimaryAction + SecondaryAction + QuickFact types

Pure value types for the detail v2 resolver layer (Tasks 3-4 add
the CapabilityResolver extensions that produce them; Task 11 wires
them into UniversalResourceDetailView v2)."
```

---

## Task 3: `CapabilityResolver.primaryAction(...)` + tests

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+PrimaryAction.swift`
- Create: `ios/TandasTests/Capabilities/CapabilityResolver+PrimaryActionTests.swift`

- [ ] **Step 1: Write the failing tests first (TDD)**

Create `ios/TandasTests/Capabilities/CapabilityResolver+PrimaryActionTests.swift`:

```swift
import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("CapabilityResolver.primaryAction")
struct CapabilityResolverPrimaryActionTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    private func makeEvent(
        status: EventStatus = .open,
        capabilities: Set<String> = ["scheduling", "rsvp"]
    ) -> ResourceRow {
        // adapt to actual ResourceRow constructor (look at fromEvent)
        // — minimal scaffolding for the test
        ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .event,
            metadata: [:],
            createdAt: .now,
            createdBy: UUID()
        )
    }

    @Test("event + rsvp + viewer hasn't RSVP'd → rsvpConfirm")
    func eventNotRSVPdGetsConfirm() {
        let action = resolver.primaryAction(
            for: makeEvent(),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .open
        )
        #expect(action.kind == .rsvpConfirm)
        #expect(!action.label.isEmpty)
        #expect(action.style == .prominent)
    }

    @Test("event + rsvp + viewer is going → rsvpCancel")
    func eventRSVPdGoingGetsCancel() {
        let action = resolver.primaryAction(
            for: makeEvent(),
            viewerRole: .member,
            rsvpStatus: .accepted,
            eventStatus: .open
        )
        #expect(action.kind == .rsvpCancel)
    }

    @Test("event + viewer is host → viewHostActions")
    func eventHostGetsActions() {
        let action = resolver.primaryAction(
            for: makeEvent(),
            viewerRole: .host,
            rsvpStatus: nil,
            eventStatus: .open
        )
        #expect(action.kind == .viewHostActions)
    }

    @Test("event closed → viewClosed (or none)")
    func eventClosedGetsClosed() {
        let action = resolver.primaryAction(
            for: makeEvent(),
            viewerRole: .member,
            rsvpStatus: .accepted,
            eventStatus: .closed
        )
        // Either viewClosed (history link) or none (footer hides) — both
        // acceptable; pick one in implementation. Test asserts it's NOT
        // confirm/cancel.
        #expect(action.kind != .rsvpConfirm)
        #expect(action.kind != .rsvpCancel)
    }

    @Test("event cancelled → none")
    func eventCancelledHidesCTA() {
        let action = resolver.primaryAction(
            for: makeEvent(),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .cancelled
        )
        #expect(action.kind == .none)
    }

    @Test("event without rsvp capability + viewer member → none")
    func eventNoRSVPCapability() {
        let action = resolver.primaryAction(
            for: makeEvent(capabilities: ["scheduling"]),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .open
        )
        #expect(action.kind == .none)
    }

    @Test("fund → openContribute placeholder")
    func fundGetsContribute() {
        let fund = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .fund,
            metadata: [:],
            createdAt: .now,
            createdBy: UUID()
        )
        let action = resolver.primaryAction(
            for: fund,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil
        )
        #expect(action.kind == .openContribute)
    }

    @Test("asset → openBooking placeholder")
    func assetGetsBooking() {
        let asset = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .asset,
            metadata: [:],
            createdAt: .now,
            createdBy: UUID()
        )
        let action = resolver.primaryAction(
            for: asset,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil
        )
        #expect(action.kind == .openBooking)
    }
}
```

**Important**: the `ResourceRow` constructor signature shown is approximate — check actual signature in `RuulCore` and adapt. The viewer-role enum (`.member`, `.host`) is also approximate — verify via `grep -n "enum.*Role\|case host\|case member" ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "primaryAction|error:" | head -10
```

Expected: FAIL with "value of type 'CapabilityResolver' has no member 'primaryAction'" (or similar).

- [ ] **Step 3: Write the implementation**

Create `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+PrimaryAction.swift`:

```swift
import Foundation

public extension CapabilityResolver {
    /// Decides the single primary CTA for the resource detail screen.
    /// Returns `.none` when no action applies — caller should hide the
    /// sticky footer entirely (don't render an empty button).
    ///
    /// Decision matrix:
    /// - event + cancelled                        → none
    /// - event + open + viewer is host            → viewHostActions
    /// - event + open + has rsvp + not RSVP'd     → rsvpConfirm
    /// - event + open + has rsvp + RSVP'd .accepted → rsvpCancel
    /// - event + closed                           → viewClosed
    /// - event without rsvp capability            → none
    /// - fund                                     → openContribute
    /// - asset                                    → openBooking
    /// - space, slot, right                       → none (Phase 2+)
    /// - unknown                                  → none
    func primaryAction(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?
    ) -> PrimaryAction {
        switch resource.resourceType {
        case .event:
            return eventPrimaryAction(
                resource: resource,
                viewerRole: viewerRole,
                rsvpStatus: rsvpStatus,
                eventStatus: eventStatus
            )
        case .fund:
            return PrimaryAction(
                label: "Aportar",
                symbol: "plus.circle.fill",
                style: .prominent,
                kind: .openContribute
            )
        case .asset:
            return PrimaryAction(
                label: "Reservar",
                symbol: "calendar.badge.plus",
                style: .prominent,
                kind: .openBooking
            )
        case .space, .slot, .right, .unknown:
            return .none
        }
    }

    private func eventPrimaryAction(
        resource: ResourceRow,
        viewerRole: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?
    ) -> PrimaryAction {
        if eventStatus == .cancelled {
            return .none
        }
        if eventStatus == .closed {
            return PrimaryAction(
                label: "Ver historial",
                symbol: "clock.arrow.circlepath",
                style: .standard,
                kind: .viewClosed
            )
        }
        if viewerRole == .host {
            return PrimaryAction(
                label: "Acciones de host",
                symbol: "person.badge.shield.checkmark",
                style: .prominent,
                kind: .viewHostActions
            )
        }
        // Need RSVP capability to offer confirm/cancel — if absent, hide.
        // (Pass 1 stored capabilities on `enabledCapabilities` Set in the
        // detail context. Resolver can take it as a param OR check via
        // module catalog. For Pass 1 of the resolver, take it as caller
        // input — see updated signature in commit if needed.)
        // For this initial impl, assume RSVP capability is on. Test 6
        // will fail; fix in next step.
        if rsvpStatus == .accepted {
            return PrimaryAction(
                label: "Cancelar mi asistencia",
                symbol: "xmark.circle",
                style: .standard,
                kind: .rsvpCancel
            )
        }
        return PrimaryAction(
            label: "Confirmar mi asistencia",
            symbol: "checkmark.circle.fill",
            style: .prominent,
            kind: .rsvpConfirm
        )
    }
}
```

The "RSVP capability gate" (Test 6) requires the resolver to know which capabilities are enabled for THIS resource. There are two ways:
- (A) Pass `enabledCapabilities: Set<String>` as a param to `primaryAction(...)`
- (B) Read from `resource.metadata["enabled_capabilities"]` if it's stored there

Option (A) is cleaner — explicit input. Update the signature accordingly:

```swift
func primaryAction(
    for resource: ResourceRow,
    viewerRole: MemberRole,
    rsvpStatus: RSVPStatus?,
    eventStatus: EventStatus?,
    enabledCapabilities: Set<String>
) -> PrimaryAction
```

And in `eventPrimaryAction`, before the host/RSVP branches:

```swift
if !enabledCapabilities.contains("rsvp") {
    return .none
}
```

Update the test cases to pass `enabledCapabilities: ["scheduling", "rsvp"]` (or empty for the gate test).

- [ ] **Step 4: Run tests to verify they pass**

```bash
make -C ios project
make -C ios test 2>&1 | grep -E "primaryAction|TEST" | head -15
```

Expected: PASS — all 8 tests green; baseline preserved (check no regressions).

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+PrimaryAction.swift \
        ios/TandasTests/Capabilities/CapabilityResolver+PrimaryActionTests.swift
git commit -m "feat(core): CapabilityResolver.primaryAction + 8 unit tests

Pure decision logic for the detail v2 sticky-footer CTA. Single
function takes (resource, viewerRole, rsvpStatus, eventStatus,
enabledCapabilities) → PrimaryAction. View dispatches on .kind.

Covers all 6 ResourceType cases + key edge cases (cancelled,
closed, capability-gated, host vs member). Phase 2 fund/asset
return placeholder kinds until those flows wire up."
```

---

## Task 4: `quickFacts(...)` + `coverSubtitle(...)` + `secondaryActions(...)` + tests

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+QuickFacts.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+CoverSubtitle.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+SecondaryActions.swift`
- Create: `ios/TandasTests/Capabilities/CapabilityResolver+QuickFactsTests.swift`
- Create: `ios/TandasTests/Capabilities/CapabilityResolver+SecondaryActionsTests.swift`

- [ ] **Step 1: Discovery — what fields does ResourceRow expose for an event?**

```bash
grep -n "public let\|public var\|public init" \
  $(grep -rln "struct ResourceRow\b" ios/Packages/RuulCore/Sources/RuulCore/) \
  | head -25
```

Capture `metadata` keys for events: `title`, `startsAt`, `location`, `host_id`, `capacity`, `attendee_count`, etc. — adapt the QuickFact label generators to read these.

- [ ] **Step 2: Write `CapabilityResolver+QuickFacts.swift`**

```swift
import Foundation

public extension CapabilityResolver {
    /// Horizontal-pill facts for the detail screen header zone.
    /// Composes facts from active capabilities. Empty array → caller
    /// hides the QuickFacts strip entirely.
    func quickFacts(
        for resource: ResourceRow,
        in group: Group,
        enabledCapabilities: Set<String>
    ) -> [QuickFact] {
        switch resource.resourceType {
        case .event:    return eventQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        case .fund:     return fundQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        case .asset:    return assetQuickFacts(resource: resource, enabledCapabilities: enabledCapabilities)
        default:        return []
        }
    }

    private func eventQuickFacts(resource: ResourceRow, enabledCapabilities: Set<String>) -> [QuickFact] {
        var facts: [QuickFact] = []

        // scheduling: date pill
        if enabledCapabilities.contains("scheduling"),
           case .string(let isoString) = resource.metadata["starts_at"] ?? .null,
           let date = ISO8601DateFormatter().date(from: isoString) {
            facts.append(QuickFact(
                id: "date",
                kind: .date,
                symbol: "calendar",
                label: date.ruulShortDateWithWeekday   // adapt to actual helper
            ))
            facts.append(QuickFact(
                id: "time",
                kind: .time,
                symbol: "clock",
                label: date.ruulShortTime
            ))
        }

        // location capability (or just metadata.location): location pill
        if case .string(let loc) = resource.metadata["location"] ?? .null, !loc.isEmpty {
            facts.append(QuickFact(
                id: "location",
                kind: .location,
                symbol: "mappin.and.ellipse",
                label: loc
            ))
        }

        // capacity (rsvp + capacity field): "8/12"
        if enabledCapabilities.contains("rsvp"),
           case .int(let capacity) = resource.metadata["capacity"] ?? .null,
           case .int(let attendees) = resource.metadata["attendee_count"] ?? .null {
            facts.append(QuickFact(
                id: "capacity",
                kind: .capacity,
                symbol: "person.2",
                label: "\(attendees)/\(capacity)"
            ))
        }

        return facts
    }

    private func fundQuickFacts(resource: ResourceRow, enabledCapabilities: Set<String>) -> [QuickFact] {
        var facts: [QuickFact] = []
        // ledger capability: balance
        if enabledCapabilities.contains("ledger"),
           case .string(let balance) = resource.metadata["balance_display"] ?? .null {
            facts.append(QuickFact(
                id: "balance",
                kind: .balance,
                symbol: "banknote",
                label: balance
            ))
        }
        // goal: progress
        if case .string(let progress) = resource.metadata["progress_display"] ?? .null {
            facts.append(QuickFact(
                id: "progress",
                kind: .progress,
                symbol: "chart.bar",
                label: progress
            ))
        }
        return facts
    }

    private func assetQuickFacts(resource: ResourceRow, enabledCapabilities: Set<String>) -> [QuickFact] {
        var facts: [QuickFact] = []
        if case .string(let status) = resource.metadata["status_display"] ?? .null {
            facts.append(QuickFact(
                id: "status",
                kind: .status,
                symbol: "circle.fill",
                label: status
            ))
        }
        if case .string(let location) = resource.metadata["location"] ?? .null, !location.isEmpty {
            facts.append(QuickFact(
                id: "location",
                kind: .location,
                symbol: "mappin.and.ellipse",
                label: location
            ))
        }
        return facts
    }
}
```

**Important caveat**: `Date+RuulFormatting` lives in RuulUI (Pass 3 Task 2-3). The resolver lives in RuulCore. RuulCore can't depend on RuulUI (would cause a cycle). Two options:
- (A) Move `Date+RuulFormatting` from RuulUI to RuulCore — tighter coupling but acceptable; the helpers are pure value-formatting
- (B) Have the resolver return `Date` raw + caller formats — leaks formatting concerns to view
- (C) Add a lightweight `DateFormatting` protocol the resolver can call (dependency injection)

Pick (A): move `Date+RuulFormatting.swift` to `ios/Packages/RuulCore/Sources/RuulCore/Utilities/Date+RuulFormatting.swift`, update SwiftLint exclusion, update imports in callers (mechanical sed). Date helpers are pure value formatting and belong in Core.

If moving the file is not desirable, fall back to (B): return `Date` + add `formattedDate: String` after the view formats. Document the choice in commit.

- [ ] **Step 3: Write `CapabilityResolver+CoverSubtitle.swift`**

```swift
import Foundation

public extension CapabilityResolver {
    /// Subtitle line for the cover hero overlay. nil → hide the line.
    /// Examples:
    ///   event:  "Hosted by Daniel · 8 going"
    ///   fund:   "$4,500 of $10,000 raised"
    ///   asset:  "Last booked by Lynda · 2 weeks ago"
    func coverSubtitle(
        for resource: ResourceRow,
        in group: Group,
        memberDirectory: [UUID: MemberWithProfile],
        enabledCapabilities: Set<String>
    ) -> String? {
        switch resource.resourceType {
        case .event:    return eventCoverSubtitle(resource: resource, memberDirectory: memberDirectory, enabledCapabilities: enabledCapabilities)
        case .fund:     return fundCoverSubtitle(resource: resource)
        case .asset:    return assetCoverSubtitle(resource: resource, memberDirectory: memberDirectory)
        default:        return nil
        }
    }

    private func eventCoverSubtitle(
        resource: ResourceRow,
        memberDirectory: [UUID: MemberWithProfile],
        enabledCapabilities: Set<String>
    ) -> String? {
        var parts: [String] = []
        if case .string(let hostIdString) = resource.metadata["host_id"] ?? .null,
           let hostId = UUID(uuidString: hostIdString),
           let host = memberDirectory[hostId]?.displayName {
            parts.append("Hosted by \(host)")
        }
        if enabledCapabilities.contains("rsvp"),
           case .int(let attendees) = resource.metadata["attendee_count"] ?? .null,
           attendees > 0 {
            parts.append("\(attendees) going")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fundCoverSubtitle(resource: ResourceRow) -> String? {
        if case .string(let raised) = resource.metadata["balance_display"] ?? .null,
           case .string(let goal) = resource.metadata["goal_display"] ?? .null {
            return "\(raised) of \(goal) raised"
        }
        return nil
    }

    private func assetCoverSubtitle(resource: ResourceRow, memberDirectory: [UUID: MemberWithProfile]) -> String? {
        if case .string(let custodianIdString) = resource.metadata["custodian_id"] ?? .null,
           let custodianId = UUID(uuidString: custodianIdString),
           let custodian = memberDirectory[custodianId]?.displayName {
            return "Custodian: \(custodian)"
        }
        return nil
    }
}
```

- [ ] **Step 4: Write `CapabilityResolver+SecondaryActions.swift`**

```swift
import Foundation

public extension CapabilityResolver {
    /// Items for the nav bar `⋯` menu, in display order. Caller groups
    /// by `section` for visual separators.
    func secondaryActions(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>
    ) -> [SecondaryAction] {
        switch resource.resourceType {
        case .event:    return eventSecondaryActions(viewerRole: viewerRole, viewerCanIssueManualFine: viewerCanIssueManualFine, enabledCapabilities: enabledCapabilities)
        default:        return commonSecondaryActions(viewerRole: viewerRole)
        }
    }

    private func eventSecondaryActions(
        viewerRole: MemberRole,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []
        let isHost = viewerRole == .host
        let isAdmin = viewerRole == .admin || viewerRole == .founder

        if isHost || isAdmin {
            items.append(SecondaryAction(label: "Editar detalles", symbol: "pencil", section: .primary, kind: .editDetails))
        }
        items.append(SecondaryAction(label: "Compartir", symbol: "square.and.arrow.up", section: .primary, kind: .share))
        items.append(SecondaryAction(label: "Agregar al calendario", symbol: "calendar.badge.plus", section: .primary, kind: .addToCalendar))
        items.append(SecondaryAction(label: "Pase de Wallet", symbol: "wallet.pass", section: .primary, kind: .generateWalletPass))

        if isHost {
            items.append(SecondaryAction(label: "Recordar a invitados", symbol: "bell.badge", section: .host, kind: .remindAttendees))
            items.append(SecondaryAction(label: "Cerrar evento", symbol: "checkmark.seal", section: .host, kind: .closeEvent))
            items.append(SecondaryAction(label: "Cancelar evento", symbol: "xmark.octagon", section: .host, kind: .cancelEvent, isDestructive: true))
        }

        if enabledCapabilities.contains("ledger") {
            items.append(SecondaryAction(label: "Ledger", symbol: "list.bullet.rectangle", section: .money, kind: .openLedger))
        }
        if viewerCanIssueManualFine {
            items.append(SecondaryAction(label: "Multa manual", symbol: "exclamationmark.triangle", section: .money, kind: .issueManualFine, isDestructive: true))
        }

        if enabledCapabilities.contains("rules") || enabledCapabilities.contains("appeal_voting") {
            items.append(SecondaryAction(label: "Acuerdos", symbol: "doc.text", section: .governance, kind: .openRules))
        }

        if isAdmin {
            items.append(SecondaryAction(label: "Archivar", symbol: "archivebox", section: .danger, kind: .archive, isDestructive: true))
        }

        return items
    }

    private func commonSecondaryActions(viewerRole: MemberRole) -> [SecondaryAction] {
        // For non-event resource types — Phase 2 expands.
        var items: [SecondaryAction] = []
        items.append(SecondaryAction(label: "Compartir", symbol: "square.and.arrow.up", section: .primary, kind: .share))
        if viewerRole == .admin || viewerRole == .founder {
            items.append(SecondaryAction(label: "Activar capability", symbol: "switch.2", section: .governance, kind: .enableCapability))
            items.append(SecondaryAction(label: "Archivar", symbol: "archivebox", section: .danger, kind: .archive, isDestructive: true))
        }
        return items
    }
}
```

- [ ] **Step 5: Write tests for QuickFacts and SecondaryActions**

Create `CapabilityResolver+QuickFactsTests.swift` with ~6 tests (event happy path, event missing fields, fund happy path, asset happy path, unknown type returns empty, slot/right return empty).

Create `CapabilityResolver+SecondaryActionsTests.swift` with ~6 tests (member sees minimal menu, host sees host section, admin sees archive, manual fine gate, capability-gated rules item, non-event types).

Mirror the test scaffolding from Task 3.

- [ ] **Step 6: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -5
make -C ios test 2>&1 | tail -10
```

Use 600000ms timeout. Expected: BUILD SUCCEEDED + all new tests green + no regressions.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+QuickFacts.swift \
        ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+CoverSubtitle.swift \
        ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver+SecondaryActions.swift \
        ios/TandasTests/Capabilities/CapabilityResolver+QuickFactsTests.swift \
        ios/TandasTests/Capabilities/CapabilityResolver+SecondaryActionsTests.swift
# If Date+RuulFormatting was moved RuulUI → RuulCore, also stage:
# ios/Packages/RuulCore/Sources/RuulCore/Utilities/Date+RuulFormatting.swift
# (deleted file from RuulUI)
git commit -m "feat(core): CapabilityResolver — quickFacts + coverSubtitle + secondaryActions

Three pure-logic resolvers complete the detail v2 resolver layer.
Tests cover happy paths + capability gating + role gating per type.

If Date+RuulFormatting was moved from RuulUI to RuulCore (to avoid
RuulCore→RuulUI dependency for the date-formatting helpers used by
quickFacts), document that here too."
```

---

## Task 5: `ResourceCoverHero.swift`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceCoverHero.swift`

- [ ] **Step 1: Inspect Group.category.ramp shape**

```bash
grep -n "public var ramp\|struct GroupColorRamp\|var bgGradient" \
  ios/Packages/RuulCore/Sources/RuulCore/GroupColorRamp.swift 2>/dev/null \
  ios/Packages/RuulCore/Sources/RuulCore/Group.swift 2>/dev/null
```

Capture: how many colors does `bgGradient.colors` expose? (2, 3, 4?) and whether `accent` is a separate field. Adapt the MeshGradient palette accordingly.

- [ ] **Step 2: Write `ResourceCoverHero.swift`**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Cover hero for the resource detail v2. Full-bleed image (when
/// `metadata.cover_image_url` is set) OR a procedural MeshGradient
/// fallback derived from the group's category ramp. Vignette overlay
/// at bottom + white-text title/date/subtitle anchored bottom-leading.
/// Status pill anchored top-trailing.
///
/// Parallax: GeometryReader-driven scale + offset on scroll. Stretches
/// when scroll-pulled-down; compresses on scroll-up.
@MainActor
public struct ResourceCoverHero: View {
    public let title: String
    public let subtitle: String?
    public let dateLabel: String?
    public let timeLabel: String?
    public let statusPill: StatusPill?
    public let coverImageURL: URL?
    public let groupCategory: GroupCategory

    public struct StatusPill: Sendable, Hashable {
        public let label: String
        public let color: Color
        public init(label: String, color: Color) {
            self.label = label
            self.color = color
        }
    }

    public init(
        title: String,
        subtitle: String? = nil,
        dateLabel: String? = nil,
        timeLabel: String? = nil,
        statusPill: StatusPill? = nil,
        coverImageURL: URL? = nil,
        groupCategory: GroupCategory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dateLabel = dateLabel
        self.timeLabel = timeLabel
        self.statusPill = statusPill
        self.coverImageURL = coverImageURL
        self.groupCategory = groupCategory
    }

    public var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let pull = max(0, -frame.minY)
            let push = max(0, frame.minY)

            ZStack(alignment: .bottomLeading) {
                coverImage
                    .frame(width: geo.size.width, height: max(coverHeight + pull, coverHeight))
                    .offset(y: -push * 0.5)
                    .clipped()
                vignette
                statusPillOverlay
                bottomOverlay
            }
            .frame(width: geo.size.width, height: coverHeight)
        }
        .frame(height: coverHeight)
    }

    private var coverHeight: CGFloat { 360 }

    @ViewBuilder
    private var coverImage: some View {
        if let url = coverImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty, .failure:
                    meshFallback
                @unknown default:
                    meshFallback
                }
            }
        } else {
            meshFallback
        }
    }

    @ViewBuilder
    private var meshFallback: some View {
        let palette = groupCategory.ramp
        // Adjust to actual GroupColorRamp shape: pick 4 colors that
        // produce a soft, brand-aligned gradient.
        MeshGradient(
            width: 2,
            height: 2,
            points: [
                .init(0, 0), .init(1, 0),
                .init(0, 1), .init(1, 1)
            ],
            colors: [
                palette.bgGradient.colors.first ?? .gray,
                palette.accent,
                palette.bgGradient.colors.last ?? .gray,
                palette.accent.opacity(0.8)
            ]
        )
    }

    private var vignette: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0),
                Color.black.opacity(0.6)
            ],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var statusPillOverlay: some View {
        if let pill = statusPill {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 6, height: 6)
                    Text(pill.label)
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, RuulSpacing.sm)
                .padding(.vertical, 6)
                .background(Capsule().fill(pill.color.opacity(0.85)))
                .padding(.trailing, RuulSpacing.md)
                .padding(.top, RuulSpacing.xl)
                Spacer().frame(width: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var bottomOverlay: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let dateLabel {
                HStack(spacing: 4) {
                    Text(dateLabel)
                    if let timeLabel {
                        Text("·")
                        Text(timeLabel)
                    }
                }
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(.white.opacity(0.95))
                .textCase(.uppercase)
            }
            Text(title)
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(.white)
                .lineLimit(3)
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(RuulSpacing.lg)
    }
}

#if DEBUG
#Preview("Event with image") {
    ResourceCoverHero(
        title: "Cena del Jueves",
        subtitle: "Hosted by Daniel · 8 going",
        dateLabel: "JUE 12 MAR",
        timeLabel: "9:00 PM",
        statusPill: .init(label: "OPEN", color: .green),
        coverImageURL: nil,
        groupCategory: .socialRecurring
    )
}
#endif
```

- [ ] **Step 3: Build**

```bash
make -C ios project
make -C ios build 2>&1 | tail -5
```

Token names (`RuulSpacing.xs/sm/md/lg/xl`, `RuulTypography.captionBold/displayLarge/callout`) may differ — adapt to actual via grep if compile fails.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceCoverHero.swift
git commit -m "feat(detail): ResourceCoverHero — full-bleed cover + parallax + overlay

Folds DetailCoverView + EventHeroTitleBlock + DetailHeaderView's
cover-time work into one polymorphic component:

  - AsyncImage when metadata.cover_image_url set
  - MeshGradient fallback from Group.category.ramp colors
  - Vignette gradient + bottom-leading white text overlay
    (date/time pill, title displayLarge, subtitle callout)
  - Top-trailing status pill (e.g. OPEN/FULL/PASSED)
  - Parallax: stretch on scroll-pull-down, compress on scroll-up

Replaces 3 zone files at cutover (Task 16); for now lives alongside."
```

---

## Task 6: `ResourceQuickFactsView.swift`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceQuickFactsView.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Horizontal pills strip showing capability-driven quick facts for
/// a resource (date / time / location / capacity / balance / etc.).
/// Source of truth: `CapabilityResolver.quickFacts(...)`. Empty array
/// → caller hides the strip entirely.
@MainActor
public struct ResourceQuickFactsView: View {
    public let facts: [QuickFact]
    public let onTapLocation: (() -> Void)?

    public init(facts: [QuickFact], onTapLocation: (() -> Void)? = nil) {
        self.facts = facts
        self.onTapLocation = onTapLocation
    }

    public var body: some View {
        if facts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.sm) {
                    ForEach(facts) { fact in
                        pill(for: fact)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func pill(for fact: QuickFact) -> some View {
        let content = HStack(spacing: 6) {
            Image(systemName: fact.symbol)
                .ruulTextStyle(RuulTypography.calloutRegular)
                .foregroundStyle(Color.ruulTextSecondary)
            Text(fact.label)
                .ruulTextStyle(RuulTypography.calloutRegular)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(Capsule().fill(Color.ruulSurface))

        if fact.kind == .location, let onTap = onTapLocation {
            Button(action: onTap) { content }
                .buttonStyle(.ruulPress)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("QuickFacts — event") {
    ResourceQuickFactsView(facts: [
        QuickFact(id: "date", kind: .date, symbol: "calendar", label: "JUE 12 MAR"),
        QuickFact(id: "time", kind: .time, symbol: "clock", label: "9:00 PM"),
        QuickFact(id: "location", kind: .location, symbol: "mappin.and.ellipse", label: "Casa de JJ"),
        QuickFact(id: "capacity", kind: .capacity, symbol: "person.2", label: "8/12")
    ])
}
#endif
```

- [ ] **Step 2: Build + commit**

```bash
make -C ios project
make -C ios build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceQuickFactsView.swift
git commit -m "feat(detail): ResourceQuickFactsView — horizontal pills strip

Polymorphic via CapabilityResolver.quickFacts(...). Renders zero-cost
when facts is empty. Tap on location pill routes to maps via
optional onTapLocation callback."
```

---

## Task 7: `ResourcePrimaryCTA.swift` (rename from DetailStickyFooterView)

**Files:**
- Rename via `git mv`: `Features/Resources/Detail/Zones/DetailStickyFooterView.swift` → `Features/Resources/Detail/ResourcePrimaryCTA.swift`
- Modify: rewrite contents to use `PrimaryAction` resolver output

- [ ] **Step 1: Move + rename file**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailStickyFooterView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourcePrimaryCTA.swift
```

- [ ] **Step 2: Replace contents**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Sticky footer button driven by `PrimaryAction` (from
/// `CapabilityResolver.primaryAction(...)`). Hidden when
/// `action.kind == .none`. Single source of CTA on detail v2.
///
/// Mounted via `.safeAreaInset(edge: .bottom)` on
/// `UniversalResourceDetailView`. Glass-frosted; respects safe area.
@MainActor
public struct ResourcePrimaryCTA: View {
    public let action: PrimaryAction
    public let onTap: () -> Void

    public init(action: PrimaryAction, onTap: @escaping () -> Void) {
        self.action = action
        self.onTap = onTap
    }

    public var body: some View {
        if action.kind == .none {
            EmptyView()
        } else {
            Button(action: onTap) {
                HStack(spacing: RuulSpacing.sm) {
                    if let symbol = action.symbol {
                        Image(systemName: symbol)
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                    Text(action.label)
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.md)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .fill(backgroundColor)
                )
            }
            .buttonStyle(.ruulPress)
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.sm)
            .padding(.top, RuulSpacing.sm)
            .background(.ultraThinMaterial)
        }
    }

    private var backgroundColor: Color {
        switch action.style {
        case .standard:    return Color.ruulAccent
        case .prominent:   return Color.ruulAccent
        case .destructive: return Color.ruulSemanticDanger
        }
    }
}

#if DEBUG
#Preview("RSVP confirm") {
    VStack {
        Spacer()
        ResourcePrimaryCTA(
            action: PrimaryAction(
                label: "Confirmar mi asistencia",
                symbol: "checkmark.circle.fill",
                style: .prominent,
                kind: .rsvpConfirm
            ),
            onTap: {}
        )
    }
}
#endif
```

- [ ] **Step 3: Update callers**

```bash
grep -rn "DetailStickyFooterView" ios/ --include="*.swift" | grep -v ".build"
```

For each callsite (likely just `UniversalResourceDetailView.swift`), it'll get rewritten in Task 11. For now leave the old reference broken — the old DetailStickyFooterView is gone and the new view has a different signature. That's OK because UniversalResourceDetailView itself is also getting replaced; transitional state.

- [ ] **Step 4: Confirm RuulSemanticDanger token exists**

```bash
grep -n "ruulSemanticDanger\|ruulAccent" ios/Packages/RuulUI/Sources/RuulUI/Tokens/RuulColors.swift | head
```

If `ruulSemanticDanger` doesn't exist, use `Color.red` or whichever token does. Adjust commit message.

- [ ] **Step 5: Build (will likely fail — that's OK)**

```bash
make -C ios project
make -C ios build 2>&1 | tail -10
```

Expected: BUILD FAILED on UniversalResourceDetailView.swift line ~47 (the `DetailStickyFooterView()` reference). Note this — Task 11 fixes by rewriting that file.

To keep the build green during interim: Task 11 must follow immediately, OR we add a temporary shim. For Pass-1-style continuous cutover with a flag, the cleanest path:

- Skip the build verification at this commit
- The build comes back green after Task 11 wires the new orchestrator behind `useNewDetail`

If you want green builds at every commit (preferred), put Tasks 7-11 under a single commit at the end of Task 11. Less reviewable though.

Pick: small commits with one orange-build interim is acceptable; the next commit (Task 11 step 6) restores green. Document in commit message.

- [ ] **Step 6: Commit (interim broken build noted)**

```bash
git add -A
git commit -m "feat(detail): ResourcePrimaryCTA — single-button sticky footer

Renamed from DetailStickyFooterView. Drives off PrimaryAction
(kind/label/symbol/style) returned by CapabilityResolver. Hidden
when action.kind == .none.

Build will fail at this commit — UniversalResourceDetailView still
references the old DetailStickyFooterView() init. Task 11 rewrites
the orchestrator and restores green."
```

---

## Task 8: `ResourceDetailPanel.swift` + `SettingsSectionView.swift`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailPanel.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift`

- [ ] **Step 1: Write `ResourceDetailPanel.swift`**

```swift
import SwiftUI
import RuulUI

/// Rounded-corner panel that "slides up" over the cover hero. Holds
/// the scroll content (sections, quick facts, etc.). The cover hero
/// sits behind it ignoring safe area top; the panel's top corners
/// reveal the cover bottom for the Apple Invites visual.
@MainActor
public struct ResourceDetailPanel<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.lg)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: RuulRadius.extraLarge,
                topTrailingRadius: RuulRadius.extraLarge,
                style: .continuous
            )
            .fill(Color.ruulBackground)
        )
        // Pull up to overlap the cover bottom for the slides-up effect.
        .offset(y: -RuulRadius.extraLarge)
    }
}
```

- [ ] **Step 2: Write `SettingsSectionView.swift`**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Collapsed accordion at the bottom of the detail v2 scroll. Owns:
///   - capability toggles (when caller provides onPresentEnableCapability)
///   - notifications preferences (placeholder for Pass 3.5)
///   - archive (caller-provided callback; absent when the viewer can't
///     archive)
///
/// Renders zero-cost when no items apply (caller hides above this).
@MainActor
public struct SettingsSectionView: View {
    public let onPresentEnableCapability: (() -> Void)?
    public let onArchive: (() -> Void)?

    @State private var isExpanded: Bool = false

    public init(
        onPresentEnableCapability: (() -> Void)?,
        onArchive: (() -> Void)?
    ) {
        self.onPresentEnableCapability = onPresentEnableCapability
        self.onArchive = onArchive
    }

    public var body: some View {
        if hasAnyAction {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    if let onPresentEnableCapability {
                        actionRow(
                            label: "Activar / desactivar capabilities",
                            symbol: "switch.2",
                            action: onPresentEnableCapability,
                            isDestructive: false
                        )
                    }
                    if let onArchive {
                        actionRow(
                            label: "Archivar este recurso",
                            symbol: "archivebox",
                            action: onArchive,
                            isDestructive: true
                        )
                    }
                }
                .padding(.top, RuulSpacing.sm)
            } label: {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text("Ajustes")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .padding(RuulSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .fill(Color.ruulSurface)
            )
            .padding(.horizontal, RuulSpacing.lg)
        }
    }

    private var hasAnyAction: Bool {
        onPresentEnableCapability != nil || onArchive != nil
    }

    private func actionRow(
        label: String,
        symbol: String,
        action: @escaping () -> Void,
        isDestructive: Bool
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: symbol)
                    .frame(width: 24)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                Spacer()
            }
            .foregroundStyle(isDestructive ? Color.ruulSemanticDanger : Color.ruulTextPrimary)
        }
        .buttonStyle(.ruulPress)
    }
}
```

- [ ] **Step 3: Build (still failing on UniversalResourceDetailView — same as Task 7)**

```bash
make -C ios build 2>&1 | tail -5
```

Expected: same failure as Task 7. Document in commit.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailPanel.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift
git commit -m "feat(detail): ResourceDetailPanel + SettingsSectionView

ResourceDetailPanel: rounded-corner wrapper that slides up over the
cover hero (Apple Invites pattern).

SettingsSectionView: collapsed accordion at scroll bottom with
capability toggle + archive entry points. Uses SwiftUI built-in
DisclosureGroup; no new primitive needed.

Build still red from Task 7's interim — Task 11 restores green."
```

---

## Task 9: NeedsAttention card restyle (in `DetailAttentionView`)

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailAttentionView.swift`

- [ ] **Step 1: Read current DetailAttentionView**

```bash
cat ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailAttentionView.swift
```

- [ ] **Step 2: Restyle as a compact card**

Repurpose to render as a single compact card (Apple Sports alert style) instead of multiple action rows:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Compact "Necesita atención" card. Renders only when
/// `context.attentionActions` is non-empty. Apple Sports alert style:
/// orange dot + bold label + summary count.
@MainActor
public struct DetailAttentionView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if !context.attentionActions.isEmpty {
            Button {
                if let first = context.attentionActions.first {
                    Task { await context.onOpenInboxAction(first) }
                }
            } label: {
                HStack(spacing: RuulSpacing.sm) {
                    Circle()
                        .fill(Color.ruulSemanticWarning)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Necesita atención")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text(summary)
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(RuulSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .fill(Color.ruulSemanticWarning.opacity(0.1))
                )
            }
            .buttonStyle(.ruulPress)
            .padding(.horizontal, RuulSpacing.lg)
            .symbolEffect(.bounce, value: context.attentionActions.count)
        }
    }

    private var summary: String {
        let count = context.attentionActions.count
        if count == 1, let action = context.attentionActions.first {
            return action.summary  // adapt to actual UserAction prop
        }
        return "\(count) acciones pendientes"
    }
}
```

If `Color.ruulSemanticWarning` doesn't exist, use `Color.orange` or check existing tokens. If `UserAction` doesn't have `summary`, use whatever short-text accessor exists (or compose from `.actionType` + `.referenceId`).

- [ ] **Step 3: Build (still red on UniversalResourceDetailView)**

```bash
make -C ios build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailAttentionView.swift
git commit -m "refactor(detail): DetailAttentionView as compact card (Apple Sports alert style)

In-place restyle: previous multi-row implementation replaced with a
single compact card (orange dot + bold label + summary count + chevron).
Tap routes to the first attention action via context.onOpenInboxAction.
.symbolEffect(.bounce) on count change.

Build still red from Tasks 7-8 — Task 11 restores green."
```

---

## Task 10: Rename current `UniversalResourceDetailView` → `Legacy`

**Files:**
- Rename via `git mv`: `Features/Resources/Detail/UniversalResourceDetailView.swift` → `Features/Resources/Detail/UniversalResourceDetailViewLegacy.swift`
- Modify: rename the public type inside the moved file

- [ ] **Step 1: Move + rename type**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailViewLegacy.swift

sed -i '' 's/\bUniversalResourceDetailView\b/UniversalResourceDetailViewLegacy/g' \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailViewLegacy.swift
```

- [ ] **Step 2: Update one callsite (RootShellSheets) to refer to Legacy**

```bash
grep -n "UniversalResourceDetailView" \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift
```

For now (until Task 14 wires the flag), point the callsite at `UniversalResourceDetailViewLegacy`. The new type doesn't exist yet — Task 11 creates it.

Edit RootShellSheets.swift's eventDetail branch (around line 271):

```swift
EventDetailHost(...)  // EventDetailHost still uses UniversalResourceDetailView internally
```

Wait — check: does RootShellSheets directly construct `UniversalResourceDetailView`, or does it construct `EventDetailHost` which then internally renders `UniversalResourceDetailView`? If the latter, RootShellSheets doesn't need an edit; only `EventDetailHost.hosted(coordinator:)` does. Verify:

```bash
grep -A 5 "EventDetailHost(" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift
grep -n "UniversalResourceDetailView" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
```

Then update whichever file actually instantiates `UniversalResourceDetailView` to use `UniversalResourceDetailViewLegacy` for now. Task 11/14 will branch on the flag.

- [ ] **Step 3: Build green again**

```bash
make -C ios project
make -C ios build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED — the legacy view is fully wired; nothing references the new type yet (it doesn't exist).

But wait — Tasks 7-9 created files that reference types not in the legacy view (`PrimaryAction`, `QuickFact`, etc.). Those types exist in RuulCore (Tasks 2-4). The new view files (`ResourcePrimaryCTA`, etc.) compile against those types. The build should be green.

If still red, look at the error — likely a stale reference to `DetailStickyFooterView` somewhere outside the legacy view. Fix.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(detail): rename UniversalResourceDetailView → Legacy

Pre-cutover step: keep the legacy implementation alive as
UniversalResourceDetailViewLegacy so the new view (Task 11) can
take the canonical name. RootShellSheets / EventDetailHost
callsites updated to the Legacy name. Behavior unchanged.

Build green: legacy view wires to all existing zone files; new
view types from Tasks 2-4 are referenced by Tasks 5-9 components
which are not yet wired into a view tree."
```

---

## Task 11: Write new `UniversalResourceDetailView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

- [ ] **Step 1: Inspect ResourceDetailContext shape**

```bash
head -80 ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailContext.swift
```

Verify the public properties used below: `resource`, `group`, `currentUserId`, `enabledCapabilities`, `memberDirectory`, `displayName`, `attentionActions`, `onPresentLedger`, `onPresentRules`, `onPresentEditResource`, `onPresentEnableCapability`, `onOpenInboxAction`, `onSelectMember`, `onDismiss`. Adapt usage if some are missing or differently named.

- [ ] **Step 2: Write the new orchestrator**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Apple Invites-inspired resource detail v2.
///
/// Layout:
///   1. ResourceCoverHero            — full-bleed, parallax, white overlay
///   2. ResourceDetailPanel          — rounded panel slides up over cover
///        a. NeedsAttention card     — DetailAttentionView restyled (Task 9)
///        b. ResourceQuickFactsView  — horizontal pills (capability-driven)
///        c. DescriptionSection      — metadata.description
///        d. RSVPSection             — capability rsvp
///        e. MoneySection            — capability ledger
///        f. RulesSection            — capability rules
///        g. ActivitySection         — last 5 + linkout
///        h. SettingsSection         — collapsed accordion (capability toggle, archive)
///   3. ResourcePrimaryCTA           — sticky footer, single button (.glassEffect)
///   4. NavigationStack toolbar      — close, share, ⋯ menu (secondaryActions)
@MainActor
public struct UniversalResourceDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.eventInteractor) private var eventInteractor
    @Environment(\.eventDetailPresenter) private var presenter

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    coverHero
                    ResourceDetailPanel {
                        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                            DetailAttentionView(context: context)
                            ResourceQuickFactsView(facts: quickFacts)
                            sections
                            SettingsSectionView(
                                onPresentEnableCapability: shouldShowEnableCapability ? context.onPresentEnableCapability : nil,
                                onArchive: nil  // wire when archive flow exists
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ResourcePrimaryCTA(action: primaryAction, onTap: dispatchPrimary)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        context.onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(secondaryActions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                dispatchSecondary(action)
                            } label: {
                                Label(action.label, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Cover hero

    @ViewBuilder
    private var coverHero: some View {
        ResourceCoverHero(
            title: context.displayName,
            subtitle: app.capabilityResolver.coverSubtitle(
                for: context.resource,
                in: context.group,
                memberDirectory: context.memberDirectory,
                enabledCapabilities: context.enabledCapabilities
            ),
            dateLabel: dateLabel,
            timeLabel: timeLabel,
            statusPill: statusPill,
            coverImageURL: context.coverImageURL,
            groupCategory: context.group.category
        )
    }

    private var dateLabel: String? {
        // Derived from resource.metadata.starts_at if event; nil otherwise.
        // Use Date+RuulFormatting helpers (see Task 4 step 2 caveat re: location).
        guard case .string(let iso) = context.resource.metadata["starts_at"] ?? .null,
              let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.ruulShortDateWithWeekday  // adapt to actual helper
    }

    private var timeLabel: String? {
        guard case .string(let iso) = context.resource.metadata["starts_at"] ?? .null,
              let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.ruulShortTime  // adapt
    }

    private var statusPill: ResourceCoverHero.StatusPill? {
        // Compose from resource status — minimal Pass-1 implementation.
        if let interactor = eventInteractor {
            let status = interactor.event.status
            switch status {
            case .open:      return .init(label: "OPEN", color: .green)
            case .closed:    return .init(label: "CERRADO", color: .gray)
            case .cancelled: return .init(label: "CANCELADO", color: .red)
            }
        }
        return nil
    }

    // MARK: - Sections (capability-gated, fixed order)

    @ViewBuilder
    private var sections: some View {
        if context.enabledCapabilities.contains("description") || hasDescription {
            DescriptionSectionView(context: context)
        }
        if context.enabledCapabilities.contains("rsvp") {
            RSVPSectionView(context: context)
        }
        if context.enabledCapabilities.contains("check_in"), eventInteractor != nil {
            CheckInSectionView(context: context)
        }
        if context.enabledCapabilities.contains("ledger") {
            MoneySectionView(context: context)
        }
        if context.enabledCapabilities.contains("rules") {
            RulesSectionView(context: context)
        }
        if context.enabledCapabilities.contains("activity") {
            ActivitySectionView(context: context)
        }
    }

    private var hasDescription: Bool {
        if case .string(let s) = context.resource.metadata["description"] ?? .null,
           !s.isEmpty {
            return true
        }
        return false
    }

    private var shouldShowEnableCapability: Bool {
        // Per spec: "Activar capability" is a dead route for events
        // (capability set is hard-seeded). Only surface for non-event types.
        context.resource.resourceType != .event
    }

    // MARK: - Resolver-driven actions

    private var primaryAction: PrimaryAction {
        let viewerRole: MemberRole = {
            // Approximate: read from memberDirectory[currentUserId]?.member.role
            // — adapt to the actual Member.roles vs role property.
            if let me = context.memberDirectory[context.currentUserId]?.member,
               me.roles.contains(.host) {
                return .host
            }
            return .member
        }()

        let rsvpStatus: RSVPStatus? = eventInteractor?.myRSVP?.status
        let eventStatus: EventStatus? = eventInteractor?.event.status

        return app.capabilityResolver.primaryAction(
            for: context.resource,
            viewerRole: viewerRole,
            rsvpStatus: rsvpStatus,
            eventStatus: eventStatus,
            enabledCapabilities: context.enabledCapabilities
        )
    }

    private var secondaryActions: [SecondaryAction] {
        let viewerRole: MemberRole = {
            if let me = context.memberDirectory[context.currentUserId]?.member,
               me.roles.contains(.host) {
                return .host
            }
            // Use admin/founder check if available
            return .member
        }()

        return app.capabilityResolver.secondaryActions(
            for: context.resource,
            viewerRole: viewerRole,
            viewerCanIssueManualFine: presenter?.canIssueManualFine ?? false,
            enabledCapabilities: context.enabledCapabilities
        )
    }

    // MARK: - Dispatch

    private func dispatchPrimary() {
        switch primaryAction.kind {
        case .rsvpConfirm:
            Task { await eventInteractor?.setRSVP(.accepted, plusOnes: 0, reason: nil) }
        case .rsvpCancel:
            presenter?.onPresentCancelAttendanceSheet()
        case .viewHostActions:
            // Open an action sheet with host actions — for Pass 1 of v2,
            // route to the closeEvent sheet as a stand-in. Pass 1.1 polishes.
            presenter?.onPresentCloseEventSheet()
        case .openContribute, .openBooking, .viewClosed, .none:
            // No-op for Pass 1 of v2 (Phase 2 wires fund/asset).
            break
        }
    }

    private func dispatchSecondary(_ action: SecondaryAction) {
        switch action.kind {
        case .editDetails:        context.onPresentEditResource()
        case .addToCalendar:      // Calendar export is on EventDetailHost; presenter doesn't expose it directly.
                                  // For Pass 1 of v2, leave as no-op + log; wire in Pass 1.1.
                                  break
        case .share:              presenter?.onPresentShareSheet()
        case .generateWalletPass: presenter?.onAddToWallet()
        case .remindAttendees:    presenter?.onPresentRemindAttendeesSheet()
        case .closeEvent:         presenter?.onPresentCloseEventSheet()
        case .cancelEvent:        presenter?.onPresentCancelEventSheet()
        case .openLedger:         context.onPresentLedger()
        case .issueManualFine:    presenter?.onPresentManualFineSheet()
        case .openRules:          context.onPresentRules()
        case .enableCapability:   context.onPresentEnableCapability()
        case .archive:            // No archive endpoint yet; Pass 2 wires.
                                  break
        }
    }
}

#if DEBUG
#Preview {
    Text("UniversalResourceDetailView v2 needs AppState + EventInteractor environment to render.")
        .padding()
}
#endif
```

This is the largest single file in the plan (~250L). Take care with adapting parameter names (`.host`, `.accepted`, `EventStatus.open`, etc.) to actual codebase shapes.

- [ ] **Step 3: Build green**

```bash
make -C ios project
make -C ios build 2>&1 | tail -25
```

Expected: BUILD SUCCEEDED. The new `UniversalResourceDetailView` exists; the legacy `UniversalResourceDetailViewLegacy` also exists; both compile.

If errors appear, the most likely issues:
- Wrong member-role enum cases (`.host` vs `.facilitator` vs `.organizer`) → grep + adjust
- Wrong RSVP status enum cases (`.accepted` vs `.going` vs `.confirmed`) → grep + adjust
- Wrong ResourceDetailContext callback names → grep + adjust
- Date helper not in scope (RuulCore can't see RuulUI) → handle per Task 4 caveat (move helpers to RuulCore OR pass formatted strings in)

Fix each error with the minimum change.

- [ ] **Step 4: Run tests (no regressions)**

```bash
make -C ios test 2>&1 | tail -10
```

Expected: 200+ tests / 40+ suites green (added ~12 from Task 3 + ~12 from Task 4).

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
git commit -m "feat(detail): UniversalResourceDetailView v2 — Apple Invites-inspired

New orchestrator. Composes:
  - ResourceCoverHero (Task 5) full-bleed parallax cover
  - ResourceDetailPanel (Task 8) rounded slides-up panel
  - DetailAttentionView (Task 9) compact alert card
  - ResourceQuickFactsView (Task 6) horizontal pills
  - 6 capability-gated sections in fixed order
  - SettingsSectionView (Task 8) collapsed accordion
  - ResourcePrimaryCTA (Task 7) sticky footer
  - NavigationStack toolbar with close + share + ⋯ menu

Resolver-driven (Tasks 3-4): primaryAction + secondaryActions +
quickFacts + coverSubtitle. Dispatch maps kinds to existing
EventDetailPresenter callbacks; non-event resource types (fund/asset)
get placeholder no-ops until Phase 2 wires them.

Build green; legacy view (UniversalResourceDetailViewLegacy) still
present — Task 14 adds the useNewDetail flag branch in callsites,
Task 16 deletes the legacy after cutover."
```

---

## Task 12: Extract `EventDetailBootstrap.swift` from EventDetailHost

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailBootstrap.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift` (extract pieces)

- [ ] **Step 1: Identify extract candidates in EventDetailHost**

Lines that move: `bootIfNeeded()` (~16L), `loadCapabilities()` (~5L), `loadAttentionActions()` (~8L), `computeCanIssueManualFine()` (~17L). Total ~50L of async setup logic.

- [ ] **Step 2: Create EventDetailBootstrap.swift**

```swift
import Foundation
import RuulCore

/// Async bootstrap for EventDetailHost: builds the EventDetailCoordinator,
/// loads enabled capabilities, hydrates attention actions, computes
/// governance gates. Pure async work — no SwiftUI references.
///
/// Returns ready-to-use state via the `BootstrapResult`. Caller (the
/// EventDetailHost view) wires the result to its @State properties.
@MainActor
public struct EventDetailBootstrap {
    public let app: AppState
    public let event: Event
    public let group: RuulCore.Group
    public let currentUserId: UUID
    public let memberDirectory: [UUID: MemberWithProfile]

    public init(
        app: AppState,
        event: Event,
        group: RuulCore.Group,
        currentUserId: UUID,
        memberDirectory: [UUID: MemberWithProfile]
    ) {
        self.app = app
        self.event = event
        self.group = group
        self.currentUserId = currentUserId
        self.memberDirectory = memberDirectory
    }

    public struct Result: Sendable {
        public let coordinator: EventDetailCoordinator
        public let enabledCapabilities: Set<String>
        public let attentionActions: [UserAction]
        public let canIssueManualFine: Bool
    }

    public func run() async -> Result {
        let coordinator = EventDetailCoordinator(
            event: event,
            group: group,
            userId: currentUserId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            checkInRepo: app.checkInRepo,
            lifecycle: app.eventLifecycle,
            notifications: app.notifications,
            walletService: app.walletService,
            analytics: EventAnalytics(analytics: app.analytics),
            realtimeFactory: app.realtimeFactory,
            systemEvents: app.systemEventEmitter,
            notificationDispatcher: app.eventNotificationDispatcher
        )

        async let capsTask = loadCapabilities()
        async let attentionTask = loadAttentionActions()
        async let canIssueTask = computeCanIssueManualFine()

        let caps = await capsTask
        let attention = await attentionTask
        let canIssue = await canIssueTask

        return Result(
            coordinator: coordinator,
            enabledCapabilities: caps,
            attentionActions: attention,
            canIssueManualFine: canIssue
        )
    }

    private func loadCapabilities() async -> Set<String> {
        let caps = (try? await app.resourceCapabilityRepo.list(resourceId: event.id)) ?? []
        return Set(caps.filter { $0.enabled }.map { $0.capabilityBlockId })
    }

    private func loadAttentionActions() async -> [UserAction] {
        let pending = (try? await app.userActionRepo.pending(
            userId: currentUserId,
            groupId: group.id
        )) ?? []
        return pending.filter { $0.referenceId == event.id && $0.resolvedAt == nil }
    }

    private func computeCanIssueManualFine() async -> Bool {
        let me = memberDirectory[currentUserId]?.member
            ?? Self.fallbackMember(userId: currentUserId, groupId: group.id)
        do {
            let decision = try await app.governance.canPerform(
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
    }

    private static func fallbackMember(userId: UUID, groupId: UUID) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            role: "member",
            roles: [.member],
            active: false,
            joinedAt: .now
        )
    }
}
```

Note: this requires `EventDetailCoordinator` (and its construction args) to be public. They already are (from Pass 1 work).

- [ ] **Step 3: Slim EventDetailHost**

Remove the 4 extracted methods from `EventDetailHost.swift`. Replace `.task { await bootIfNeeded() }` with:

```swift
.task {
    guard coordinator == nil else { return }
    let bootstrap = EventDetailBootstrap(
        app: app, event: event, group: group,
        currentUserId: currentUserId, memberDirectory: memberDirectory
    )
    let result = await bootstrap.run()
    coordinator = result.coordinator
    enabledCapabilities = result.enabledCapabilities
    attentionActions = result.attentionActions
    canIssueManualFine = result.canIssueManualFine
}
```

Drop the `loadCapabilities`/`loadAttentionActions`/`computeCanIssueManualFine` `.task` modifiers (now done in bootstrap). Keep the realtime task + onDisappear.

- [ ] **Step 4: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -10
make -C ios test 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests green.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailBootstrap.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
git commit -m "refactor(detail): extract EventDetailBootstrap from EventDetailHost

Pulls async setup (coordinator construction, capability load,
attention hydration, governance check) into EventDetailBootstrap.run()
which returns a Sendable Result struct.

EventDetailHost shrinks ~50L; bootstrap is now pure async logic
(no SwiftUI refs) and the three previously-parallel .task modifiers
become one task using async let for parallelism."
```

---

## Task 13: Extract `EventDetailSheets.swift` ViewModifier

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailSheets.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift` (apply ViewModifier)

- [ ] **Step 1: Create EventDetailSheets.swift**

A ViewModifier that takes references to all the @State + closures needed by the 10 sheets, and applies all 10 `.ruulSheet(...)` modifiers in one place.

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Centralizes the 10 sheet/cover modifiers EventDetailHost owns.
/// Apply via `.eventDetailSheets(host: self)` on the hosted view.
///
/// All bindings + callbacks come from the EventDetailHost via the
/// `Bindings` value bundle, keeping this ViewModifier stateless.
public struct EventDetailSheets: ViewModifier {
    public struct Bindings {
        public let coordinator: EventDetailCoordinator
        public let group: RuulCore.Group
        public let currentUserId: UUID
        public let memberDirectory: [UUID: MemberWithProfile]
        public let calendarService: CalendarExportService?
        public let onEditEvent: (Event) -> Void
        public let sheet: Binding<EventDetailHost.Sheet?>
        public let attendeeRoute: Binding<MemberWithProfile?>
        public let manualFineCoordinator: AddManualFineCoordinator?
        public let ledgerCoordinator: ResourceLedgerCoordinator?
        public let rulesCoordinator: ResourceRulesCoordinator?
    }

    let b: Bindings

    public init(_ bindings: Bindings) {
        self.b = bindings
    }

    public func body(content: Content) -> some View {
        content
            .ruulSheet(isPresented: bindingForSheet(.share)) {
                ShareEventSheet(
                    isPresented: bindingForSheet(.share),
                    event: b.coordinator.event,
                    groupVocabulary: b.group.eventVocabulary,
                    hostName: hostName(for: b.coordinator.event),
                    onAddToCalendar: { addToCalendar(event: b.coordinator.event) }
                )
            }
            .ruulSheet(isPresented: bindingForSheet(.qr)) {
                MemberQRSheet(
                    isPresented: bindingForSheet(.qr),
                    eventId: b.coordinator.event.id,
                    memberId: b.coordinator.myRSVP?.userId ?? b.currentUserId,
                    eventTitle: b.coordinator.event.title
                )
            }
            .ruulSheet(isPresented: bindingForSheet(.cancelEvent)) {
                CancelEventSheet(isPresented: bindingForSheet(.cancelEvent)) { reason in
                    Task { await b.coordinator.cancelEvent(reason: reason) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.cancelAttendance)) {
                CancelAttendanceSheet(
                    isPresented: bindingForSheet(.cancelAttendance),
                    isAfterDeadline: isAfterRSVPDeadline(coordinator: b.coordinator)
                ) { reason in
                    Task { await b.coordinator.setRSVP(.declined, plusOnes: 0, reason: reason) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.remindAttendees)) {
                RemindAttendeesSheet(
                    isPresented: bindingForSheet(.remindAttendees),
                    pendingCount: b.coordinator.rsvps.filter { $0.status == .pending }.count,
                    eventTitle: b.coordinator.event.title,
                    vocabulary: b.group.eventVocabulary
                ) {
                    Task { _ = await b.coordinator.sendHostReminders() }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.closeEvent)) {
                CloseEventSheet(
                    isPresented: bindingForSheet(.closeEvent),
                    vocabulary: b.group.eventVocabulary
                ) {
                    Task { await b.coordinator.closeEvent(autoGenerateEnabled: false) }
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.manualFine)) {
                if let mf = b.manualFineCoordinator {
                    AddManualFineSheet(
                        isPresented: bindingForSheet(.manualFine),
                        coordinator: mf,
                        currentUserId: b.currentUserId
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.ledger)) {
                if let lc = b.ledgerCoordinator {
                    ResourceLedgerSheet(
                        isPresented: bindingForSheet(.ledger),
                        coordinator: lc,
                        groupVocabulary: b.group.eventVocabulary
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.rules)) {
                if let rc = b.rulesCoordinator {
                    ResourceRulesSheet(
                        isPresented: bindingForSheet(.rules),
                        coordinator: rc
                    )
                }
            }
            .ruulSheet(isPresented: bindingForSheet(.attendees)) {
                AttendeesListSheet(
                    rsvps: b.coordinator.rsvps,
                    memberDirectory: b.memberDirectory
                ) { userId in
                    b.sheet.wrappedValue = nil
                    if let mwp = b.memberDirectory[userId] {
                        b.attendeeRoute.wrappedValue = mwp
                    }
                }
            }
            .sheet(item: b.attendeeRoute) { mwp in
                NavigationStack {
                    MemberDetailView(
                        memberWithProfile: mwp,
                        group: b.group,
                        isCurrentUser: mwp.member.userId == b.currentUserId
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }

    private func bindingForSheet(_ kind: EventDetailHost.Sheet) -> Binding<Bool> {
        Binding(
            get: { b.sheet.wrappedValue == kind },
            set: { newValue in
                if newValue {
                    b.sheet.wrappedValue = kind
                } else if b.sheet.wrappedValue == kind {
                    b.sheet.wrappedValue = nil
                }
            }
        )
    }

    private func hostName(for event: Event) -> String? {
        guard let hostId = event.hostId else { return nil }
        return b.memberDirectory[hostId]?.displayName
    }

    private func isAfterRSVPDeadline(coordinator: EventDetailCoordinator) -> Bool {
        guard let deadline = coordinator.event.rsvpDeadline else { return false }
        return Date.now > deadline
    }

    private func addToCalendar(event: Event) {
        guard let calendarService = b.calendarService else { return }
        Task {
            _ = try? await calendarService.addToCalendar(event, vocabulary: b.group.eventVocabulary)
        }
    }
}

public extension View {
    func eventDetailSheets(_ bindings: EventDetailSheets.Bindings) -> some View {
        modifier(EventDetailSheets(bindings))
    }
}
```

This requires `EventDetailHost.Sheet` to be `public` (currently it's likely internal — promote it if needed).

- [ ] **Step 2: Refactor EventDetailHost to use the modifier**

Replace the long chain of `.ruulSheet(...)` modifiers in `hosted(coordinator:)` with:

```swift
.eventDetailSheets(EventDetailSheets.Bindings(
    coordinator: coordinator,
    group: group,
    currentUserId: currentUserId,
    memberDirectory: memberDirectory,
    calendarService: calendarService,
    onEditEvent: onEditEvent,
    sheet: $sheet,
    attendeeRoute: $attendeeRoute,
    manualFineCoordinator: manualFineCoordinator,
    ledgerCoordinator: ledgerCoordinator,
    rulesCoordinator: rulesCoordinator
))
```

- [ ] **Step 3: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -10
make -C ios test 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests green.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailSheets.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
git commit -m "refactor(detail): extract EventDetailSheets ViewModifier

Pulls the 10 .ruulSheet(...) modifiers into a single ViewModifier
applied via .eventDetailSheets(bindings). EventDetailHost shrinks
~150L; sheet logic + share callsite + cancel callsite all moved
into one focused file. Behavior identical."
```

---

## Task 14: Wire `useNewDetail` flag in EventDetailHost

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift`

- [ ] **Step 1: Branch on the flag in `hosted(coordinator:)`**

Find the line that constructs `UniversalResourceDetailViewLegacy(context:)` (or the renamed Legacy view) and replace with:

```swift
private func hosted(coordinator: EventDetailCoordinator) -> some View {
    Group {
        if app.useNewDetail {
            UniversalResourceDetailView(context: detailContext(coordinator: coordinator))
        } else {
            UniversalResourceDetailViewLegacy(context: detailContext(coordinator: coordinator))
        }
    }
    .environment(\.eventInteractor, coordinator)
    .environment(\.eventDetailPresenter, presenter)
    .task { await coordinator.refresh() }
    .task { await coordinator.startRealtime() }
    .onDisappear { coordinator.stopRealtime() }
    .eventDetailSheets(EventDetailSheets.Bindings(...))
    .onChange(of: sheet) { _, newValue in
        Task { await prepareCoordinator(for: newValue) }
    }
}
```

- [ ] **Step 2: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -10
make -C ios test 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests green. The flag defaults to `false` so legacy behavior persists.

- [ ] **Step 3: Manual smoke (flag still OFF)**

Build for simulator + manually verify a couple flows still work via the legacy path. (You can't toggle the flag via UI — that's lldb only. So just verify the default-false path is unbroken.)

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
git commit -m "feat(detail): wire useNewDetail flag in EventDetailHost

EventDetailHost branches on app.useNewDetail between the new
UniversalResourceDetailView (Task 11) and the legacy
UniversalResourceDetailViewLegacy. Default false → legacy behavior
preserved. Task 15 flips the flag after manual smoke."
```

---

## Task 15: Flip `useNewDetail` to true + manual smoke

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`

- [ ] **Step 1: Flip the flag**

Change `useNewDetail: Bool = false` to `useNewDetail: Bool = true` in AppState.swift (around line 80, post-Task-1).

- [ ] **Step 2: Run full test suite**

```bash
make -C ios test 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests green.

- [ ] **Step 3: Manual simulator smoke (flag now ON)**

Build + open in simulator. Manually verify:
- Tap an event in Home → new detail presents (cover hero visible)
- RSVP CTA visible at bottom
- Tap CTA → action fires (RSVP confirms or sheet opens)
- Tap ⋯ menu → secondary actions visible per role
- Tap close → dismisses
- Group switch refreshes detail

If anything is broken, document + fix BEFORE committing the flip.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "feat(detail): flip useNewDetail to true — v2 is now the default

Manual simulator smoke green. New detail v2 (Apple Invites-inspired,
cover hero + sticky CTA + nav-bar chrome) is now the default for
event detail. Legacy view (UniversalResourceDetailViewLegacy) still
present but unreached; Task 16 deletes it.

Device smoke deferred to founder verification (Liquid Glass + real
parallax need hardware iOS 26)."
```

---

## Task 16: Delete `UniversalResourceDetailViewLegacy` + obsolete zone files

**Files:**
- Delete (`git rm`): `UniversalResourceDetailViewLegacy.swift`
- Delete (`git rm`): `Zones/DetailTopNavView.swift`, `Zones/DetailHeaderView.swift`, `Zones/EventHeroTitleBlock.swift`, `Zones/DetailPrimaryActions.swift`, `Zones/DetailActionsBar.swift`, `Zones/DetailCoverView.swift`
- Modify: `EventDetailHost.swift` (remove the `if app.useNewDetail` branch — always use the new view)

- [ ] **Step 1: Verify zero references to legacy types**

```bash
for f in UniversalResourceDetailViewLegacy DetailTopNavView DetailHeaderView EventHeroTitleBlock DetailPrimaryActions DetailActionsBar DetailCoverView; do
  echo "=== $f ==="
  grep -rn "\b$f\b" ios/ --include="*.swift" \
    | grep -v ".build\|DerivedData" \
    | grep -v "Features/Resources/Detail/UniversalResourceDetailViewLegacy.swift" \
    | grep -v "Zones/$f.swift" \
    | head -5
done
```

For each type, the only references should be inside other Zones/ files (intra-folder) + possibly EventDetailHost (the conditional we're about to remove).

If a non-internal reference exists, that's a caller we missed. Fix (rewire to the new view's equivalent or delete) before deleting the file.

- [ ] **Step 2: Remove the flag conditional in EventDetailHost**

In `EventDetailHost.swift`, replace:

```swift
if app.useNewDetail {
    UniversalResourceDetailView(context: detailContext(coordinator: coordinator))
} else {
    UniversalResourceDetailViewLegacy(context: detailContext(coordinator: coordinator))
}
```

With:

```swift
UniversalResourceDetailView(context: detailContext(coordinator: coordinator))
```

- [ ] **Step 3: Delete the 7 files**

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailViewLegacy.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailTopNavView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailHeaderView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/EventHeroTitleBlock.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailPrimaryActions.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailActionsBar.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/DetailCoverView.swift
```

- [ ] **Step 4: Remove empty Zones/ directory if empty**

```bash
ls ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Zones/
```

If only `DetailAttentionView.swift` and `DetailStickyFooterView.swift` remain (kept per Tasks 7+9), leave the directory. If empty after the deletions, `rmdir` it.

If `DetailStickyFooterView.swift` was renamed to `ResourcePrimaryCTA.swift` and moved out (Task 7), only `DetailAttentionView.swift` remains. Leave or move as you prefer; cleanest is to leave a single-file Zones/ alone.

- [ ] **Step 5: Build + test**

```bash
make -C ios project
make -C ios build 2>&1 | tail -10
make -C ios test 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(detail): delete legacy view + obsolete zone files

Cutover complete. Removes:
  UniversalResourceDetailViewLegacy.swift       (was 131L)
  Zones/DetailTopNavView.swift                  (130L)
  Zones/DetailHeaderView.swift                  (86L)
  Zones/EventHeroTitleBlock.swift               (167L)
  Zones/DetailPrimaryActions.swift              (82L)
  Zones/DetailActionsBar.swift                  (112L)
  Zones/DetailCoverView.swift                   (98L)

EventDetailHost simplifies — useNewDetail flag conditional removed,
always uses the new UniversalResourceDetailView."
```

---

## Task 17: Cleanup — review `Layouts/EventInvitesContent.swift`

**Files:**
- Possibly delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Layouts/EventInvitesContent.swift`

- [ ] **Step 1: Check usage**

```bash
grep -rn "EventInvitesContent" ios/ --include="*.swift" | grep -v ".build" | head
```

If zero references outside the file itself, delete:

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Layouts/EventInvitesContent.swift
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Layouts 2>/dev/null
```

If references exist, leave + document why.

- [ ] **Step 2: Build + commit**

```bash
make -C ios project
make -C ios build 2>&1 | tail -3
git add -A
git commit -m "chore(detail): cleanup — delete dead EventInvitesContent.swift

[Or skip if file still in use; document why.]"
```

---

## Task 18: Final metrics + push + PR

- [ ] **Step 1: Verify metrics**

```bash
echo "=== Files in Detail/ ==="
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail -name "*.swift" | wc -l
echo "=== Lines in Detail/ ==="
find ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail -name "*.swift" | xargs wc -l 2>/dev/null | tail -1
echo "=== EventDetailHost.swift size ==="
wc -l ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
echo "=== Action surfaces ==="
echo "Sticky footer (ResourcePrimaryCTA): 1"
echo "Nav bar ⋯ menu (UniversalResourceDetailView toolbar): 1"
echo "=== Floating chrome over content ==="
grep -rn "ZStack(alignment: .top)\|DetailTopNavView" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ | grep -v ".build"
echo "=== Tests ==="
make -C ios test 2>&1 | tail -3
```

Expected:
- Files: ≤ 25 (target)
- Lines: ≤ 3,800 (target)
- EventDetailHost: ≤ 130L (target)
- Floating chrome: zero
- Tests: 200+ / 40+

- [ ] **Step 2: Final marker commit**

```bash
git commit --allow-empty -m "chore(detail-v2): metrics verified, ready to merge

Final state:
  Files in Detail/:                  $(find ... | wc -l)  (target ≤ 25)
  Lines in Detail/:                  $(find ... | wc -l)  (target ≤ 3,800)
  EventDetailHost.swift:             $(wc -l ...) (target ≤ 130L)
  Action surfaces:                   2 (sticky CTA + nav bar ⋯ menu)
  Floating chrome over content:      0
  useNewDetail flag:                 true (default)
  Tests:                             200+ / 40+ green

Apple Invites-inspired layout shipped: cover hero + parallax +
white overlay + single CTA + native NavigationStack chrome."
```

- [ ] **Step 3: Push + open PR**

```bash
git push -u origin HEAD:detail-redesign/v2
gh pr create --head detail-redesign/v2 --base main \
  --title "Detail v2: Apple Invites-inspired UniversalResourceDetailView redesign" \
  --body "$(cat <<'EOF'
## Summary
Full redesign of the polymorphic resource detail screen. Apple Invites pattern: cover hero (full-bleed, parallax, white overlay) + single sticky CTA + native NavigationStack chrome with ⋯ menu for secondary actions.

## What changed
- New resolver layer in RuulCore: PrimaryAction + SecondaryAction + QuickFact + 4 CapabilityResolver extensions (~12+ unit tests covering the decision matrix)
- New view layer in RuulFeatures: ResourceCoverHero + ResourceQuickFactsView + ResourcePrimaryCTA + ResourceDetailPanel + SettingsSectionView
- 6 zone files deleted (DetailTopNavView, DetailHeaderView, EventHeroTitleBlock, DetailPrimaryActions, DetailActionsBar, DetailCoverView)
- EventDetailHost split: Bootstrap (async setup) + Sheets (10-sheet ViewModifier) + slimmed Host
- Section order changed from capability-order to user-question-order

## Metrics
| Indicator | Before | After |
|---|---|---|
| Files in Detail/ | 35 | ≤ 25 |
| Lines | ~5,700 | ≤ 3,800 |
| EventDetailHost.swift | 438L | ≤ 130L |
| Action surfaces | 4 | 2 |
| Floating chrome | yes | no |

Spec: docs/superpowers/specs/2026-05-14-universal-resource-detail-redesign.md

## Test plan
- [x] make -C ios test green (200+ / 40+)
- [x] make -C ios build green with useNewDetail = true
- [ ] Manual founder smoke on iPhone (cover hero visible, RSVP CTA works, ⋯ menu items dispatch correctly)
- [ ] Device smoke for parallax + Liquid Glass nav bar
EOF
)"
```

---

## Self-review notes

**Spec coverage:**
- Apple Invites cover hero → Task 5 ✓
- Single CTA + sticky footer → Task 7 ✓
- Native NavigationStack chrome → Task 11 (toolbar items) ✓
- Section order = user question order → Task 11 (fixed `sections` builder) ✓
- Resolver layer (4 extensions) → Tasks 3-4 ✓
- ResourceQuickFactsView polymorphic → Task 6 ✓
- Procedural MeshGradient fallback → Task 5 ✓
- EventDetailHost split → Tasks 12-13 ✓
- useNewDetail feature flag → Tasks 1, 14, 15 ✓
- Delete 6 zone files → Task 16 ✓
- Settings section accordion → Task 8 (DisclosureGroup, no new primitive) ✓
- Cover subtitle resolver → Task 4 ✓
- ResourceTypeChrome statusPillText → in Task 11 inline (`statusPill` computed) ✓ (not in a separate resolver method since it's specifically per-type)

**Placeholders:** scanned. The "TODO" patterns I caught:
- Task 7 step 5 says "skip the build verification at this commit" — accepted as documented interim breakage with a clear restoration commit. Not a placeholder, an intentional micro-stage.
- Task 11 step 2 dispatch dispatches `addToCalendar` as no-op for Pass 1 of v2 — documented as deferred to "Pass 1.1". Acceptable.

**Type consistency:**
- `MemberRole` referenced in Tasks 3-4-11 — assumes `.host`, `.member`, `.admin`, `.founder` cases. Verify against actual via grep before Task 3.
- `RSVPStatus` cases (`.accepted`, `.pending`, `.declined`) — verify.
- `EventStatus` cases (`.open`, `.closed`, `.cancelled`) — verify.
- `Color.ruulSemanticDanger` / `.ruulSemanticWarning` — verify; fall back to `.red`/`.orange` if absent.
- Date helpers (`ruulShortDateWithWeekday`, `ruulShortTime`) — Pass 3 added these but they live in RuulUI; Task 4 caveats the RuulCore→RuulUI dependency.

If implementation surfaces any drift, the implementer subagent adapts at compile-error-fix time.

## Risks recap

| Risk | Mitigation |
|---|---|
| Date helpers in RuulUI not visible from RuulCore (Task 4) | Move them to RuulCore Utilities (mechanical) OR have view layer do the formatting (less clean) |
| MemberRole / RSVPStatus / EventStatus enum case names differ from spec assumptions | Discovery grep at start of each affected task; adapt |
| Color tokens (`ruulSemanticDanger`) may not exist | Fall back to system colors; add token in Pass 3.5 if needed |
| Build red across Tasks 7-10 (intentional micro-stages) | Task 11 restores; if blocked, batch-commit at end of Task 11 instead of per-task |
| EventDetailHost.Sheet visibility (private → public) needed by Task 13 ViewModifier | Promote to public in Task 13 |
| `MeshGradient` palette argument shape vs `GroupColorRamp` | Discovery in Task 5 step 1; adapt |
| Manual smoke at Task 15 surfaces UX issues | Fix in Task 15 before flipping; don't ship a broken default |

---

## References

- Spec: `docs/superpowers/specs/2026-05-14-universal-resource-detail-redesign.md`
- Frontend remodel passes 1-3: `docs/superpowers/plans/2026-05-14-frontend-remodel-pass{1,2,3}.md`
- Constitution: `Plans/Active/Constitution.md`
- Vision: `Plans/Active/Vision.md`
- AppShell canonical: `Plans/Active/AppShell.md`
- Design principles: `docs/DesignPrinciples.md`
- Memorias: `project_resource_detail_capability_driven`, `feedback_no_hardcoded_verticals`, `feedback_create_flow_defaults`, `feedback_rules_ux_human`
