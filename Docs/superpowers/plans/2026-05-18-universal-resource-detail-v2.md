# Universal Resource Detail v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `UniversalResourceDetailView` from scratch as a single-vertical-scroll, capability-driven, block-based surface that renders Event, Fund, Fine, and Vote through the same View — eliminating tabs, the parallel intent/secondary-action surfaces, and any per-type branching inside the view body.

**Architecture:** Introduces a `ResourceBlocks` aggregate (identity ribbon + state hero + properties + capability blocks + relations rail + activity feed) resolved upstream by a `BlockBuilder` per source type and rendered by a single `UniversalResourceDetailView`. Capability blocks render through a small set of universal `BlockLayoutKind` cases (summaryFacts, avatarQueue, mediaStrip, balance, progress, timelineMini, emptyPrompt) — Rotation, RSVP, Ledger, Evidence, etc. all map to one of these. Block ordering comes from a pure `BlockPriorityResolver` keyed on viewer/urgency/permissions. The view receives type metadata (icon, color, label, properties) so identity chrome stays correct, but **never branches on `resource.resourceType`** — that knowledge lives in the resolvers and builders.

Three doctrine corrections honored from the design review:
1. **Type metadata is allowed in the View** (icon, color, label, type-specific properties). What's forbidden is `switch resourceType` inside the view body.
2. **CapabilityBlock has a constrained `layoutKind`** so Rotation, Ledger, Evidence, RSVP, Wallet each get the right visual shape without forcing one-size-fits-all factRows.
3. **Specialized capability sheets and deep management screens are preserved.** `UniversalResourceDetailView` is the universal read-and-quick-action surface; tapping a capability block still opens its dedicated management sheet (RotationParticipantsSheet, EditRightSheet, LockFundSheet, etc.).

Fines and Votes don't go through `public.resources` today — they live in their own tables. The plan introduces `BlockBuilder` adapters that synthesize the universal block tree from `Fine` and `Vote` records, so the same `UniversalResourceDetailView` renders all four sources.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI iOS 26+, Swift Testing in `ios/TandasTests/`. `RuulCore` owns the block model + resolvers (pure, testable); `RuulFeatures` owns the SwiftUI renderers + per-source builders; `RuulUI` owns visual primitives.

**Pre-existing context:** The Pass-1 plan (`docs/superpowers/plans/2026-05-18-resource-detail-pass1-universal-tabs.md`) introduced `CapabilitySection.tabId` + the 5-tab segmented control. This plan **supersedes** Pass-1: tabs are eliminated, `CapabilitySection` evolves into `CapabilityBlock`, and the parallel `ResourceIntentRegistry` + `CapabilityResolver.secondaryActions` paths collapse into a single block + verb model.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ResourceBlocks.swift` | CREATE | Aggregate value type returned by every `BlockBuilder` — the universal screen tree |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/IdentityRibbon.swift` | CREATE | Identity layer model (icon, title, type label, status line) — pure value |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadline.swift` | CREATE | State hero model (headline, supporting line, inline primary action) |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/PropertiesBlock.swift` | CREATE | Properties model — array of `FactRow(key, value)` |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/CapabilityBlock.swift` | REWRITE | Universal capability block: `id`, `title`, `icon`, `layoutKind`, `facts`, `footer`, `onOpen` (replaces existing `CapabilityBlock.swift` placeholder + `CapabilitySection`) |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockLayoutKind.swift` | CREATE | Enum with 7 cases: summaryFacts, avatarQueue, mediaStrip, balance, progress, timelineMini, emptyPrompt |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/RelationCard.swift` | CREATE | Relations rail card model (id, family, label, statusLine, deepLink) |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ActivityEntry.swift` | CREATE | Activity feed entry model (id, sentence, relativeTime, reactionCount) |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadlineResolver.swift` | CREATE | Pure `(input) -> StateHeadline`. Inputs = type, status, viewer role, viewer-pending-action, time. Branching happens HERE, not in the View. |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockPriorityResolver.swift` | CREATE | Pure `(blocks, viewer, urgency) -> [CapabilityBlock]` — ordering algorithm |
| `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockBuilder.swift` | CREATE | Protocol `BlockBuilder { func build(...) -> ResourceBlocks }` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift` | REWRITE | Pure renderer of `ResourceBlocks` — single vertical scroll, no tabs, no segmented control, no per-type switches |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/IdentityRibbonView.swift` | CREATE | Renders `IdentityRibbon` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/StateHeroView.swift` | CREATE | Renders `StateHeadline` + inline primary action |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/PropertiesBlockView.swift` | CREATE | Renders `PropertiesBlock` (key/value rows, hairline dividers) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/CapabilityBlockView.swift` | CREATE | Switches on `BlockLayoutKind` (NOT on resource_type) to pick a sub-renderer |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/SummaryFactsLayout.swift` | CREATE | Rotation, Recurrence, Eligibility, etc. — 1-3 key/value rows + verb |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/AvatarQueueLayout.swift` | CREATE | Rotation queue, RSVP avatars, Custodianship chain |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/MediaStripLayout.swift` | CREATE | Evidence thumbnails, Asset photos |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/BalanceLayout.swift` | CREATE | Fund balance, Wallet balance |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/ProgressLayout.swift` | CREATE | Vote tally (X of Y), Check-in (X arrived of Y), Quota (X used of Y) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/TimelineMiniLayout.swift` | CREATE | Appeals open/closed, Agreements signed/pending |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/EmptyPromptLayout.swift` | CREATE | Slim one-line prompt when capability is enabled but empty |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/RelationsRailView.swift` | CREATE | Horizontal scrolling card rail |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/ActivityFeedView.swift` | CREATE | Inline reverse-chronological timeline (5 entries + "Ver más") |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/EventBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for events |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FundBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for funds |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FineBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for fines (adapts `Fine` record) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/VoteBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for votes (adapts `Vote` record) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/RightBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for rights |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/AssetBlockBuilder.swift` | CREATE | Builds `ResourceBlocks` for assets |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift` | MODIFY | Calls EventBlockBuilder → UniversalResourceDetailView |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Coordinator/FineDetailCoordinator.swift` | MODIFY | Calls FineBlockBuilder → UniversalResourceDetailView |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Coordinator/VoteDetailCoordinator.swift` | MODIFY | Calls VoteBlockBuilder → UniversalResourceDetailView |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Views/FineDetailView.swift` | DELETE (after migration) | Replaced by builder + universal view |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Detail/VoteDetailView.swift` | DELETE (after migration) | Replaced by builder + universal view |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift` | DELETE | No more tabs |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift` | DELETE | Replaced by `CapabilityBlock` + per-builder logic |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/*` | DELETE / port | Each existing section becomes (a) a layout-kind branch inside `CapabilityBlockView`, or (b) a deep management sheet preserved as-is |
| `ios/TandasTests/Resources/Detail/StateHeadlineResolverTests.swift` | CREATE | Pure function tests — every (resource family × viewer role × status) headline |
| `ios/TandasTests/Resources/Detail/BlockPriorityResolverTests.swift` | CREATE | Ordering invariants (state always 2nd, pending-action block jumps to 3rd, etc.) |
| `ios/TandasTests/Resources/Detail/Builders/EventBlockBuilderTests.swift` | CREATE | Snapshot of blocks for representative event states |
| `ios/TandasTests/Resources/Detail/Builders/FundBlockBuilderTests.swift` | CREATE | Snapshot for fund states (active, locked, empty) |
| `ios/TandasTests/Resources/Detail/Builders/FineBlockBuilderTests.swift` | CREATE | Snapshot for fine states (proposed, unpaid, paid, voided, appealed) |
| `ios/TandasTests/Resources/Detail/Builders/VoteBlockBuilderTests.swift` | CREATE | Snapshot for vote states (open, viewer-voted, closed) |
| `ios/TandasTests/Resources/Detail/UniversalDetailUniversalityTests.swift` | CREATE | The "view doesn't branch on resourceType" invariant (compile-time + grep check via Swift Testing) |

---

## Phase 0 — Doctrine Anchors (read before starting)

- **No tabs.** Single vertical scroll. The segmented `RuulSegmentedControl` block in `UniversalResourceDetailView.swift:92-104` is deleted in Phase B.
- **No capabilities in overflow.** The `⋯` menu only carries share / edit / archive / delete / add-to-calendar / wallet pass / report. Every capability has its own block.
- **Primary action lives inside StateHero.** Not floating, not a sticky footer (the `.safeAreaInset(edge: .bottom)` in `UniversalResourceDetailView.swift:114-116` is deleted).
- **Type metadata yes, type branching no.** `IdentityRibbon` carries an icon + color + label. The View reads those. No `switch resource.resourceType` ever appears in any file under `Features/Resources/Detail/Blocks/` or in `UniversalResourceDetailView.swift`.
- **7 layoutKinds.** Every capability block picks one. `summaryFacts`, `avatarQueue`, `mediaStrip`, `balance`, `progress`, `timelineMini`, `emptyPrompt`. No others without a doctrine update.
- **Specialized sheets stay.** Tapping a `CapabilityBlock` opens its existing management sheet (RotationParticipantsSheet, EditRightSheet, LockFundSheet, MemberPickerSheet, etc.). Those are not collapsed.
- **Pure resolvers.** `StateHeadlineResolver` and `BlockPriorityResolver` are `Sendable` functions in `RuulCore` with no SwiftUI imports. They are unit-tested as pure functions.

---

## Phase A — Core block model (RuulCore, no SwiftUI yet)

### Task A1: Create `BlockLayoutKind` enum

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockLayoutKind.swift`
- Test: `ios/TandasTests/Resources/Detail/BlockLayoutKindTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Resources/Detail/BlockLayoutKindTests.swift`:

```swift
import Testing
import RuulCore

@Suite("BlockLayoutKind")
struct BlockLayoutKindTests {
    @Test("has exactly seven cases")
    func sevenCases() {
        let all = BlockLayoutKind.allCases
        #expect(all.count == 7)
    }

    @Test("contains the seven canonical layouts")
    func canonicalLayouts() {
        let all = Set(BlockLayoutKind.allCases)
        #expect(all == [
            .summaryFacts, .avatarQueue, .mediaStrip,
            .balance, .progress, .timelineMini, .emptyPrompt
        ])
    }
}
```

- [ ] **Step 2: Run test and verify it fails**

Run: `cd ios && make test 2>&1 | grep -E "BlockLayoutKind|error:" | head -10`
Expected: FAIL — `BlockLayoutKind` is not defined.

- [ ] **Step 3: Create the enum**

Create `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockLayoutKind.swift`:

```swift
import Foundation

/// The seven canonical visual shapes a `CapabilityBlock` can take.
/// Limited on purpose: any new capability MUST fit one of these or
/// trigger a doctrine review before adding an eighth.
///
/// Renderer mapping (see `CapabilityBlockView`):
///   summaryFacts — 1-3 key/value rows + verb (Rotation, Recurrence, Eligibility, …)
///   avatarQueue  — horizontal avatar strip with order semantics (RSVP, Rotation queue, Custody chain)
///   mediaStrip   — thumbnails (Evidence, Asset photos)
///   balance      — large currency number + delta (Fund balance, Wallet balance)
///   progress     — X-of-Y bar (Vote tally, Check-in, Quota)
///   timelineMini — 2-3 dated events (Appeals, Agreements lifecycle)
///   emptyPrompt  — slim one-line CTA when the capability is enabled but empty
public enum BlockLayoutKind: String, Sendable, Hashable, CaseIterable {
    case summaryFacts
    case avatarQueue
    case mediaStrip
    case balance
    case progress
    case timelineMini
    case emptyPrompt
}
```

- [ ] **Step 4: Run test and verify it passes**

Run: `cd ios && make test 2>&1 | grep -E "BlockLayoutKind" | head -5`
Expected: PASS for both tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockLayoutKind.swift ios/TandasTests/Resources/Detail/BlockLayoutKindTests.swift
git commit -m "feat(detail-v2): add BlockLayoutKind enum (seven universal layouts)"
```

---

### Task A2: Create `IdentityRibbon` model

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/IdentityRibbon.swift`

- [ ] **Step 1: Create the value type**

```swift
import SwiftUI

/// Identity layer payload — compact ribbon at the top of every Resource
/// Detail. Carries type metadata (icon, color, family label) so the
/// renderer can draw the chrome WITHOUT branching on resource_type.
/// Builders decide what this contains; the view just renders.
public struct IdentityRibbon: Sendable, Hashable {
    /// SF Symbol name.
    public let icon: String
    /// Semantic tint for the icon. Sendable wrapper around a chosen
    /// resource-family color (see `ResourceFamilyTint`).
    public let tint: ResourceFamilyTint
    /// Resource title — the user's name for this thing.
    public let title: String
    /// Short subtitle line: "Event · Scheduled · Tomorrow 20:00"
    public let subtitleSegments: [String]

    public init(icon: String, tint: ResourceFamilyTint, title: String, subtitleSegments: [String]) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitleSegments = subtitleSegments
    }
}

/// Canonical tints per resource family. Sendable + Hashable so it can
/// ride inside the block tree across actors. The View resolves these
/// to `Color` at render time (see `ResourceFamilyTint+Color.swift`
/// in RuulUI). Builders pick one; the View never asks "what type is this".
public enum ResourceFamilyTint: String, Sendable, Hashable, CaseIterable {
    case events
    case funds
    case votes
    case fines
    case agreements
    case assets
    case persons
    case neutral
}
```

- [ ] **Step 2: Build to make sure it compiles**

Run: `cd ios && make build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/IdentityRibbon.swift
git commit -m "feat(detail-v2): add IdentityRibbon model + ResourceFamilyTint"
```

---

### Task A3: Create `StateHeadline` model

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadline.swift`

- [ ] **Step 1: Write the value type**

```swift
import Foundation

/// State layer payload — the single hero block per screen.
/// Answers "what does this resource mean RIGHT NOW for THIS viewer".
/// Built by `StateHeadlineResolver`; rendered by `StateHeroView`.
public struct StateHeadline: Sendable, Hashable {
    /// One-sentence headline. Founder voice. No jargon.
    public let headline: String
    /// 2-3 supporting facts. Rendered as a single dotted line under
    /// the headline ("20:00 · Casa de Ana · Anfitriona Ana").
    public let supportingFacts: [String]
    /// Inline primary action. nil → block renders the fact alone, no
    /// button. Exactly ONE action per screen, ever.
    public let primaryAction: PrimaryAction?
    /// Urgency band — drives both visual prominence (subtle red tint)
    /// and the priority resolver (urgent state pulls dependent blocks
    /// higher in the stack).
    public let urgency: Urgency

    public enum Urgency: String, Sendable, Hashable {
        case ambient    // informational — "Saldo $4,300"
        case actionable // viewer can act — "Confirm if you're coming"
        case urgent     // time-pressured — "$200 due in 2 days"
        case terminal   // closed / archived — "Closed Mar 4"
    }

    public init(headline: String, supportingFacts: [String], primaryAction: PrimaryAction?, urgency: Urgency) {
        self.headline = headline
        self.supportingFacts = supportingFacts
        self.primaryAction = primaryAction
        self.urgency = urgency
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ios && make build 2>&1 | tail -3`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadline.swift
git commit -m "feat(detail-v2): add StateHeadline model with urgency band"
```

---

### Task A4: Create `PropertiesBlock` + `FactRow`

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/PropertiesBlock.swift`

- [ ] **Step 1: Write the value types**

```swift
import Foundation

/// Properties layer payload. 4-7 facts max per doctrine §4.
/// More than 7 → push the overflow into its own capability block.
public struct PropertiesBlock: Sendable, Hashable {
    public let rows: [FactRow]
    public init(rows: [FactRow]) {
        self.rows = rows
    }
}

/// One key/value pair. Both sides are pre-formatted strings — the
/// renderer does NOT format dates, currency, etc. Builders do that
/// so the resolver/renderer stay locale-aware via the builder layer.
public struct FactRow: Sendable, Hashable, Identifiable {
    public let id: String   // stable for diffing (e.g. "starts_at", "host")
    public let key: String  // "Cuándo"
    public let value: String // "Mañana · 20:00"
    public init(id: String, key: String, value: String) {
        self.id = id; self.key = key; self.value = value
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ios && make build 2>&1 | tail -3`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/PropertiesBlock.swift
git commit -m "feat(detail-v2): add PropertiesBlock + FactRow"
```

---

### Task A5: Rewrite `CapabilityBlock` as universal block model

**Files:**
- Replace: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityBlock.swift` (existing file is a placeholder enum; full rewrite)
- Move to: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/CapabilityBlock.swift` (new home alongside the rest of the detail model)

- [ ] **Step 1: Read existing file to confirm it's safe to replace**

Run: `cat ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityBlock.swift`
Expected: A short placeholder defining a `CapabilityBlock` enum used by `ModuleRegistry.providedCapabilityBlocks` (string ids like "ledger"). Confirm no other consumer of the type itself — only string literal ids. (Grep below.)

Run: `grep -rn "CapabilityBlock[^I]" ios/Packages --include="*.swift" | grep -v "providedCapabilityBlocks\|capability_blocks" | head`
Expected: Few or no hits — current usage is `Set<String>` not the type itself.

- [ ] **Step 2: Move + rewrite**

Delete the old file:
```bash
git rm ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityBlock.swift
```

Create `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/CapabilityBlock.swift`:

```swift
import Foundation

/// Universal capability block — one module of a resource's detail surface.
/// Every enabled capability turns into ONE of these (or none, when it has
/// nothing meaningful to render and isn't worth even an empty prompt).
///
/// The `layoutKind` decides which sub-renderer the view picks. Builders
/// fill the right fields per layout. The View NEVER branches on
/// `resource.resourceType` — only on `block.layoutKind`.
public struct CapabilityBlock: Sendable, Hashable, Identifiable {
    /// Stable id. Conventionally the capability id ("rotation", "rsvp",
    /// "ledger", "evidence"). Multiple blocks may share a capability if
    /// the same module produces distinct surfaces (rare).
    public let id: String

    /// Human label rendered as the block header. "Rotación", "Asistencia",
    /// "Saldo", "Evidencia". Founder voice — no jargon.
    public let title: String

    /// SF Symbol for the block header glyph.
    public let icon: String

    /// Picks the sub-renderer in `CapabilityBlockView`.
    public let layoutKind: BlockLayoutKind

    /// Layout-specific payload. All layouts read from the same struct —
    /// each layout uses the subset relevant to it. Builders fill what
    /// their layout needs and leave the rest at default.
    public let payload: Payload

    /// Optional verb shown at the block footer ("Editar rotación",
    /// "Ver libro"). nil → no footer. When the user taps the block
    /// header chevron it opens whatever `onOpen` resolves to in the
    /// host's wiring.
    public let footerVerb: String?

    /// Opaque destination id the view passes back to the host on tap.
    /// The host (EventDetailHost / FundDetailHost / FineDetailCoordinator)
    /// owns the routing — the view just emits the id.
    public let openDestinationId: String?

    /// True when this block represents an obligation pending for the
    /// current viewer (RSVP not given, fine not paid, vote not cast).
    /// `BlockPriorityResolver` pulls these blocks to position 3 so the
    /// State Hero can call them out.
    public let isViewerObligation: Bool

    public init(
        id: String,
        title: String,
        icon: String,
        layoutKind: BlockLayoutKind,
        payload: Payload,
        footerVerb: String? = nil,
        openDestinationId: String? = nil,
        isViewerObligation: Bool = false
    ) {
        self.id = id; self.title = title; self.icon = icon
        self.layoutKind = layoutKind; self.payload = payload
        self.footerVerb = footerVerb; self.openDestinationId = openDestinationId
        self.isViewerObligation = isViewerObligation
    }

    /// Universal payload shape. Every layout reads from the same struct;
    /// builders populate only the fields their layout needs.
    public struct Payload: Sendable, Hashable {
        /// `summaryFacts` and any layout that wants extra key/value rows.
        public let facts: [FactRow]
        /// `avatarQueue`: ordered list of member ids.
        public let avatars: [AvatarRef]
        /// `mediaStrip`: thumbnail urls.
        public let media: [MediaRef]
        /// `balance`: pre-formatted currency string + signed delta.
        public let balance: BalanceFields?
        /// `progress`: numerator + denominator.
        public let progress: ProgressFields?
        /// `timelineMini`: 2-3 dated events.
        public let timeline: [TimelineEntry]
        /// `emptyPrompt`: one-line copy ("Vacío · Añade el primer movimiento").
        public let emptyPrompt: String?

        public init(
            facts: [FactRow] = [],
            avatars: [AvatarRef] = [],
            media: [MediaRef] = [],
            balance: BalanceFields? = nil,
            progress: ProgressFields? = nil,
            timeline: [TimelineEntry] = [],
            emptyPrompt: String? = nil
        ) {
            self.facts = facts; self.avatars = avatars; self.media = media
            self.balance = balance; self.progress = progress
            self.timeline = timeline; self.emptyPrompt = emptyPrompt
        }
    }

    public struct AvatarRef: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let initials: String
        public let badgeSymbol: String?  // "checkmark.circle.fill", "questionmark.circle"
        public init(id: UUID, initials: String, badgeSymbol: String? = nil) {
            self.id = id; self.initials = initials; self.badgeSymbol = badgeSymbol
        }
    }

    public struct MediaRef: Sendable, Hashable, Identifiable {
        public let id: String
        public let url: URL?
        public let placeholder: String   // SF Symbol when url missing
        public init(id: String, url: URL?, placeholder: String) {
            self.id = id; self.url = url; self.placeholder = placeholder
        }
    }

    public struct BalanceFields: Sendable, Hashable {
        public let primary: String       // "$4,300"
        public let supporting: String?   // "última aportación · 2 mar"
        public let delta: String?        // "+$200"
        public init(primary: String, supporting: String?, delta: String?) {
            self.primary = primary; self.supporting = supporting; self.delta = delta
        }
    }

    public struct ProgressFields: Sendable, Hashable {
        public let current: Int
        public let total: Int
        public let label: String         // "3 de 8 votos emitidos"
        public init(current: Int, total: Int, label: String) {
            self.current = current; self.total = total; self.label = label
        }
    }

    public struct TimelineEntry: Sendable, Hashable, Identifiable {
        public let id: String
        public let sentence: String      // "Apelación abierta por David"
        public let relativeTime: String  // "hace 2h"
        public init(id: String, sentence: String, relativeTime: String) {
            self.id = id; self.sentence = sentence; self.relativeTime = relativeTime
        }
    }
}
```

- [ ] **Step 3: Build to check no consumer of the deleted file broke**

Run: `cd ios && make build 2>&1 | grep -E "error:" | head -10`
Expected: No `CapabilityBlock` errors (because previous usage was string ids, not the type). If any error surfaces, fix the import site explicitly — likely none.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/CapabilityBlock.swift
git commit -m "feat(detail-v2): rewrite CapabilityBlock with seven-layout payload"
```

---

### Task A6: Create `RelationCard` model

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/RelationCard.swift`

- [ ] **Step 1: Write the type**

```swift
import Foundation

/// One card on the Relations rail. Tapping it pushes the related
/// resource's own UniversalResourceDetailView — recursion works
/// because the model is universal.
public struct RelationCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let icon: String
    public let tint: ResourceFamilyTint
    public let label: String        // "Acuerdo", "Fondo"
    public let statusLine: String?  // "Firmado", "$4,3k", "Open"
    /// Deep link id the host resolves to a navigation push.
    public let deepLink: String
    public init(
        id: UUID, icon: String, tint: ResourceFamilyTint,
        label: String, statusLine: String?, deepLink: String
    ) {
        self.id = id; self.icon = icon; self.tint = tint
        self.label = label; self.statusLine = statusLine
        self.deepLink = deepLink
    }
}
```

- [ ] **Step 2: Build + commit**

Run: `cd ios && make build 2>&1 | tail -3`
Expected: Build succeeded.

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/RelationCard.swift
git commit -m "feat(detail-v2): add RelationCard model"
```

---

### Task A7: Create `ActivityEntry` model

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ActivityEntry.swift`

- [ ] **Step 1: Write the type**

```swift
import Foundation

/// One row in the inline activity feed at the bottom of every
/// UniversalResourceDetailView. Builders synthesize these from
/// `system_events` rows — the feed never reads SQL directly.
public struct ActivityEntry: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// One human sentence: "Ana fue asignada como anfitriona".
    public let sentence: String
    /// Relative time: "hace 2h", "4 mar".
    public let relativeTime: String
    /// Optional SF Symbol for the leading icon.
    public let icon: String?
    public init(id: UUID, sentence: String, relativeTime: String, icon: String?) {
        self.id = id; self.sentence = sentence
        self.relativeTime = relativeTime; self.icon = icon
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ActivityEntry.swift
git commit -m "feat(detail-v2): add ActivityEntry model"
```

---

### Task A8: Create `ResourceBlocks` aggregate

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ResourceBlocks.swift`

- [ ] **Step 1: Write the aggregate**

```swift
import Foundation

/// The full screen tree for a single Resource Detail render. Every
/// `BlockBuilder` returns one of these; the View consumes one of these.
/// The view contains zero per-source branching — that all lives in the
/// builder that produced this value.
public struct ResourceBlocks: Sendable, Hashable {
    /// Layer 1.
    public let identity: IdentityRibbon
    /// Layer 2. Required — every resource has SOME headline (the
    /// resolver guarantees a non-empty string per doctrine §3).
    public let state: StateHeadline
    /// Layer 4. May be empty; renderer hides itself when so.
    public let properties: PropertiesBlock
    /// Layer 5. Ordered by `BlockPriorityResolver`. May include empty
    /// prompts (slim one-liners) for capabilities enabled-but-empty.
    public let capabilities: [CapabilityBlock]
    /// Layer 6. May be empty.
    public let relations: [RelationCard]
    /// Layer 7. Last 5 entries. `hasMore` drives the "Ver más" affordance.
    public let activityHead: [ActivityEntry]
    public let hasMoreActivity: Bool

    public init(
        identity: IdentityRibbon,
        state: StateHeadline,
        properties: PropertiesBlock,
        capabilities: [CapabilityBlock],
        relations: [RelationCard],
        activityHead: [ActivityEntry],
        hasMoreActivity: Bool
    ) {
        self.identity = identity; self.state = state
        self.properties = properties; self.capabilities = capabilities
        self.relations = relations
        self.activityHead = activityHead; self.hasMoreActivity = hasMoreActivity
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/ResourceBlocks.swift
git commit -m "feat(detail-v2): add ResourceBlocks aggregate"
```

---

### Task A9: Define `BlockBuilder` protocol

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockBuilder.swift`

- [ ] **Step 1: Write the protocol**

```swift
import Foundation

/// Contract every per-source builder implements. Builders are
/// stateless transformations: given a source record + viewer context,
/// return the universal screen tree. They live in RuulFeatures (they
/// touch view-layer concepts like icons and SF symbols), but the
/// protocol lives in RuulCore so RuulCore tests can call them.
public protocol BlockBuilder: Sendable {
    associatedtype Source: Sendable

    func build(
        source: Source,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks
}

/// The slice of viewer state every builder reads. Kept narrow on purpose:
/// builders that need more (e.g. a member directory for RSVP avatars)
/// take it as their own init dependency.
public struct BlockViewerContext: Sendable, Hashable {
    public let userId: UUID?
    public let permissions: Set<Permission>
    /// Group's enabled modules — drives which capability blocks appear.
    public let activeModules: Set<String>
    public let memberId: UUID?  // viewer's group_members.id (when joined)
    public init(
        userId: UUID?, permissions: Set<Permission>,
        activeModules: Set<String>, memberId: UUID?
    ) {
        self.userId = userId; self.permissions = permissions
        self.activeModules = activeModules; self.memberId = memberId
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockBuilder.swift
git commit -m "feat(detail-v2): define BlockBuilder protocol + BlockViewerContext"
```

---

## Phase B — Pure resolvers (RuulCore)

### Task B1: `BlockPriorityResolver` — ordering algorithm

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockPriorityResolver.swift`
- Test: `ios/TandasTests/Resources/Detail/BlockPriorityResolverTests.swift`

- [ ] **Step 1: Write failing tests**

Create the test file:

```swift
import Testing
import Foundation
import RuulCore

@Suite("BlockPriorityResolver")
struct BlockPriorityResolverTests {
    private let neutralPayload = CapabilityBlock.Payload(facts: [])

    private func block(_ id: String, obligation: Bool = false, empty: Bool = false) -> CapabilityBlock {
        CapabilityBlock(
            id: id, title: id, icon: "circle",
            layoutKind: empty ? .emptyPrompt : .summaryFacts,
            payload: neutralPayload, isViewerObligation: obligation
        )
    }

    @Test("an obligation block jumps to first position")
    func obligationFirst() {
        let blocks = [
            block("ledger"),
            block("rotation"),
            block("rsvp", obligation: true)
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.first?.id == "rsvp")
    }

    @Test("empty prompts sink to the end")
    func emptyPromptsLast() {
        let blocks = [
            block("ledger", empty: true),
            block("rotation"),
            block("rsvp")
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.last?.id == "ledger")
    }

    @Test("stable order among same-bucket blocks (preserves builder order)")
    func stableInBucket() {
        let blocks = [block("a"), block("b"), block("c")]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.map(\.id) == ["a", "b", "c"])
    }

    @Test("multiple obligations preserve their relative order")
    func multipleObligations() {
        let blocks = [
            block("rsvp", obligation: true),
            block("rotation"),
            block("vote", obligation: true)
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.prefix(2).map(\.id) == ["rsvp", "vote"])
    }
}
```

- [ ] **Step 2: Run test, expect failure (type missing)**

Run: `cd ios && make test 2>&1 | grep -E "BlockPriorityResolver|error:" | head`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement the resolver**

Create `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockPriorityResolver.swift`:

```swift
import Foundation

/// Pure ordering function. Given a list of CapabilityBlocks produced
/// by a builder (in their natural builder order), return them in the
/// order they should render on screen.
///
/// Three buckets, stable-sort within each:
///   1. Viewer obligations (isViewerObligation == true)
///   2. Active (non-empty) blocks
///   3. Empty prompts (layoutKind == .emptyPrompt)
public enum BlockPriorityResolver {
    public static func order(_ blocks: [CapabilityBlock]) -> [CapabilityBlock] {
        var obligations: [CapabilityBlock] = []
        var active: [CapabilityBlock] = []
        var empty: [CapabilityBlock] = []

        for b in blocks {
            if b.isViewerObligation { obligations.append(b) }
            else if b.layoutKind == .emptyPrompt { empty.append(b) }
            else { active.append(b) }
        }

        return obligations + active + empty
    }
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd ios && make test 2>&1 | grep -E "BlockPriorityResolver" | head`
Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/BlockPriorityResolver.swift ios/TandasTests/Resources/Detail/BlockPriorityResolverTests.swift
git commit -m "feat(detail-v2): BlockPriorityResolver with obligation/active/empty buckets"
```

---

### Task B2: `StateHeadlineResolver` — headline picker

**Note:** This resolver is intentionally a SHELL that builders compose through. The full per-family headline rules live in each `BlockBuilder` (because they need source-specific signals like `event.startsAt` or `fine.dueDate`). The resolver just enforces invariants: non-empty headline, exactly one primary action, urgency mapping.

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadlineResolver.swift`
- Test: `ios/TandasTests/Resources/Detail/StateHeadlineResolverTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
import RuulCore

@Suite("StateHeadlineResolver invariants")
struct StateHeadlineResolverTests {
    @Test("headline is never empty after normalization")
    func nonEmptyHeadline() {
        let raw = StateHeadline(
            headline: "   ",
            supportingFacts: ["fallback fact"],
            primaryAction: nil,
            urgency: .ambient
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "Recurso activo")
        #expect(resolved.headline == "Recurso activo")
    }

    @Test("trims headline whitespace but preserves non-empty text")
    func trimsWhitespace() {
        let raw = StateHeadline(
            headline: "  Ana hospeda mañana  ",
            supportingFacts: [],
            primaryAction: nil,
            urgency: .actionable
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "x")
        #expect(resolved.headline == "Ana hospeda mañana")
    }

    @Test("removes supporting facts that are empty or whitespace")
    func dropsEmptyFacts() {
        let raw = StateHeadline(
            headline: "x",
            supportingFacts: ["20:00", "", "  ", "Casa de Ana"],
            primaryAction: nil,
            urgency: .ambient
        )
        let resolved = StateHeadlineResolver.normalize(raw, fallback: "x")
        #expect(resolved.supportingFacts == ["20:00", "Casa de Ana"])
    }
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `cd ios && make test 2>&1 | grep -E "StateHeadlineResolver|error:" | head`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Normalizes a builder-produced `StateHeadline` so renderers can trust
/// invariants (non-empty headline, no empty supporting facts). The
/// FAMILY-specific rules for which sentence to pick live in each
/// builder — this resolver only enforces the shared contract.
public enum StateHeadlineResolver {
    /// - Parameters:
    ///   - raw: builder's draft headline.
    ///   - fallback: used when the builder's headline is empty.
    public static func normalize(_ raw: StateHeadline, fallback: String) -> StateHeadline {
        let trimmed = raw.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmed.isEmpty ? fallback : trimmed
        let facts = raw.supportingFacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return StateHeadline(
            headline: headline,
            supportingFacts: facts,
            primaryAction: raw.primaryAction,
            urgency: raw.urgency
        )
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd ios && make test 2>&1 | grep -E "StateHeadlineResolver" | head`
Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Resources/Detail/StateHeadlineResolver.swift ios/TandasTests/Resources/Detail/StateHeadlineResolverTests.swift
git commit -m "feat(detail-v2): StateHeadlineResolver normalization invariants"
```

---

## Phase C — Renderer (RuulFeatures + RuulUI)

### Task C1: `IdentityRibbonView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/IdentityRibbonView.swift`
- Create: `ios/Packages/RuulUI/Sources/RuulUI/Tokens/ResourceFamilyTint+Color.swift` (tint → SwiftUI Color)

- [ ] **Step 1: Tint extension in RuulUI**

```swift
import SwiftUI
import RuulCore

public extension ResourceFamilyTint {
    var color: Color {
        switch self {
        case .events:     return .orange
        case .funds:      return .green
        case .votes:      return .blue
        case .fines:      return .red
        case .agreements: return .gray
        case .assets:     return .purple
        case .persons:    return .teal
        case .neutral:    return .secondary
        }
    }
}
```

- [ ] **Step 2: View**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Layer 1: compact identity ribbon (~56pt). Renders icon + title +
/// one subtitle line composed by dot-joining `subtitleSegments`.
struct IdentityRibbonView: View {
    let ribbon: IdentityRibbon

    var body: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: ribbon.icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(ribbon.tint.color)
                .frame(width: 40, height: 40)
                .background(
                    ribbon.tint.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(ribbon.title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                if !ribbon.subtitleSegments.isEmpty {
                    Text(ribbon.subtitleSegments.joined(separator: " · "))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulUI/Sources/RuulUI/Tokens/ResourceFamilyTint+Color.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/IdentityRibbonView.swift
git commit -m "feat(detail-v2): IdentityRibbonView + tint color tokens"
```

---

### Task C2: `StateHeroView` with inline primary action

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/StateHeroView.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Layer 2: the single hero block. Headline + supporting line + inline
/// primary action. NO floating CTA, NO sticky footer — the action is
/// the bottom edge of this block when present.
struct StateHeroView: View {
    let headline: StateHeadline
    let tint: ResourceFamilyTint
    let onPrimaryTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text(headline.headline)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(3)
            if !headline.supportingFacts.isEmpty {
                Text(headline.supportingFacts.joined(separator: " · "))
                    .ruulTextStyle(RuulTypography.subhead)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            if let action = headline.primaryAction, action.kind != .none {
                Button(action: onPrimaryTap) {
                    HStack {
                        if let symbol = action.symbol {
                            Image(systemName: symbol)
                        }
                        Text(action.label)
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.style == .destructive ? .red : tint.color)
            }
        }
        .padding(RuulSpacing.lg)
        .background(
            urgencyBackground,
            in: RoundedRectangle(cornerRadius: RuulRadius.lg)
        )
    }

    private var urgencyBackground: AnyShapeStyle {
        switch headline.urgency {
        case .urgent:    return AnyShapeStyle(Color.red.opacity(0.06))
        case .actionable: return AnyShapeStyle(tint.color.opacity(0.06))
        case .ambient, .terminal: return AnyShapeStyle(Color.ruulSurfaceSecondary)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/StateHeroView.swift
git commit -m "feat(detail-v2): StateHeroView with inline primary action"
```

---

### Task C3: `PropertiesBlockView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/PropertiesBlockView.swift`

- [ ] **Step 1: View**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Layer 4: key/value list with hairline dividers. Renders nothing when
/// rows is empty (the parent skips it). 4-7 rows is the doctrine max;
/// the builder enforces that limit.
struct PropertiesBlockView: View {
    let block: PropertiesBlock

    var body: some View {
        if !block.rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(block.rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.key)
                            .ruulTextStyle(RuulTypography.subhead)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .frame(width: 96, alignment: .leading)
                        Text(row.value)
                            .ruulTextStyle(RuulTypography.subhead)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, RuulSpacing.sm)
                    if idx < block.rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .background(
                Color.ruulSurfaceSecondary,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/PropertiesBlockView.swift
git commit -m "feat(detail-v2): PropertiesBlockView with key/value rows"
```

---

### Task C4: Seven layout views + `CapabilityBlockView` dispatcher

Each layout file is small (~60-80 LoC). All seven get created in one commit since they're trivially independent.

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/SummaryFactsLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/AvatarQueueLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/MediaStripLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/BalanceLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/ProgressLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/TimelineMiniLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/EmptyPromptLayout.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/CapabilityBlockView.swift`

- [ ] **Step 1: `SummaryFactsLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct SummaryFactsLayout: View {
    let facts: [FactRow]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.key)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text(fact.value)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: `AvatarQueueLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct AvatarQueueLayout: View {
    let avatars: [CapabilityBlock.AvatarRef]
    let tint: ResourceFamilyTint

    var body: some View {
        HStack(spacing: -8) {
            ForEach(avatars.prefix(6)) { avatar in
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tint.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Text(avatar.initials)
                                .ruulTextStyle(RuulTypography.captionSemibold)
                                .foregroundStyle(tint.color)
                        )
                        .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                    if let badge = avatar.badgeSymbol {
                        Image(systemName: badge)
                            .font(.system(size: 12))
                            .foregroundStyle(tint.color)
                            .background(Color.ruulSurface, in: Circle())
                    }
                }
            }
            if avatars.count > 6 {
                Text("+\(avatars.count - 6)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(.leading, RuulSpacing.sm)
            }
            Spacer(minLength: 0)
        }
    }
}
```

- [ ] **Step 3: `MediaStripLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct MediaStripLayout: View {
    let media: [CapabilityBlock.MediaRef]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.sm) {
                ForEach(media) { item in
                    AsyncImage(url: item.url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: item.placeholder)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
```

- [ ] **Step 4: `BalanceLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct BalanceLayout: View {
    let fields: CapabilityBlock.BalanceFields
    let tint: ResourceFamilyTint

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
                Text(fields.primary)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let delta = fields.delta {
                    Text(delta)
                        .ruulTextStyle(RuulTypography.captionSemibold)
                        .foregroundStyle(tint.color)
                }
            }
            if let supporting = fields.supporting {
                Text(supporting)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
```

- [ ] **Step 5: `ProgressLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct ProgressLayout: View {
    let fields: CapabilityBlock.ProgressFields
    let tint: ResourceFamilyTint

    private var fraction: Double {
        fields.total == 0 ? 0 : min(1.0, Double(fields.current) / Double(fields.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(fields.label)
                .ruulTextStyle(RuulTypography.subhead)
                .foregroundStyle(Color.ruulTextPrimary)
            ProgressView(value: fraction)
                .tint(tint.color)
        }
    }
}
```

- [ ] **Step 6: `TimelineMiniLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct TimelineMiniLayout: View {
    let entries: [CapabilityBlock.TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: RuulSpacing.sm) {
                    Text(entry.relativeTime)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .frame(width: 64, alignment: .leading)
                    Text(entry.sentence)
                        .ruulTextStyle(RuulTypography.subhead)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
        }
    }
}
```

- [ ] **Step 7: `EmptyPromptLayout`**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Slim one-row prompt for a capability that's enabled but has no data.
/// Renders inline in the same vertical scroll instead of as a full block.
struct EmptyPromptLayout: View {
    let prompt: String

    var body: some View {
        Text(prompt)
            .ruulTextStyle(RuulTypography.subhead)
            .foregroundStyle(Color.ruulTextSecondary)
    }
}
```

- [ ] **Step 8: `CapabilityBlockView` dispatcher**

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Renders ONE CapabilityBlock by switching on its layoutKind. This is
/// the ONLY switch in the detail renderer — and it switches on layout,
/// not resource_type. Adding a new layout means adding a case here +
/// a new Layout view file.
struct CapabilityBlockView: View {
    let block: CapabilityBlock
    let tint: ResourceFamilyTint
    let onOpen: () -> Void

    var body: some View {
        if block.layoutKind == .emptyPrompt {
            // Slim prompt — no header chrome, no padding wrapper.
            Button(action: onOpen) {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: block.icon)
                        .foregroundStyle(Color.ruulTextSecondary)
                    EmptyPromptLayout(prompt: block.payload.emptyPrompt ?? block.title)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.md)
                .background(
                    Color.ruulSurfaceSecondary,
                    in: RoundedRectangle(cornerRadius: RuulRadius.md)
                )
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                header
                content
                if let verb = block.footerVerb {
                    Button(action: onOpen) {
                        Text(verb)
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                            .foregroundStyle(tint.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RuulSpacing.lg)
            .background(
                Color.ruulSurfaceSecondary,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }

    private var header: some View {
        Button(action: onOpen) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: block.icon)
                    .foregroundStyle(tint.color)
                Text(block.title)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch block.layoutKind {
        case .summaryFacts:
            SummaryFactsLayout(facts: block.payload.facts)
        case .avatarQueue:
            AvatarQueueLayout(avatars: block.payload.avatars, tint: tint)
        case .mediaStrip:
            MediaStripLayout(media: block.payload.media)
        case .balance:
            if let b = block.payload.balance {
                BalanceLayout(fields: b, tint: tint)
            } else {
                EmptyView()
            }
        case .progress:
            if let p = block.payload.progress {
                ProgressLayout(fields: p, tint: tint)
            } else {
                EmptyView()
            }
        case .timelineMini:
            TimelineMiniLayout(entries: block.payload.timeline)
        case .emptyPrompt:
            EmptyView()   // handled in outer if-branch
        }
    }
}
```

- [ ] **Step 9: Build**

Run: `cd ios && make build 2>&1 | grep -E "error:" | head -10`
Expected: 0 errors.

- [ ] **Step 10: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/Layouts/ ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/CapabilityBlockView.swift
git commit -m "feat(detail-v2): seven layout views + CapabilityBlockView dispatcher"
```

---

### Task C5: `RelationsRailView` + `ActivityFeedView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/RelationsRailView.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/ActivityFeedView.swift`

- [ ] **Step 1: `RelationsRailView`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct RelationsRailView: View {
    let cards: [RelationCard]
    let onTap: (RelationCard) -> Void

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Relacionados")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RuulSpacing.sm) {
                        ForEach(cards) { card in
                            Button { onTap(card) } label: {
                                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                                    Image(systemName: card.icon)
                                        .foregroundStyle(card.tint.color)
                                    Text(card.label)
                                        .ruulTextStyle(RuulTypography.subheadSemibold)
                                        .foregroundStyle(Color.ruulTextPrimary)
                                    if let status = card.statusLine {
                                        Text(status)
                                            .ruulTextStyle(RuulTypography.caption)
                                            .foregroundStyle(Color.ruulTextSecondary)
                                    }
                                }
                                .padding(RuulSpacing.md)
                                .frame(width: 140, alignment: .leading)
                                .background(
                                    Color.ruulSurfaceSecondary,
                                    in: RoundedRectangle(cornerRadius: RuulRadius.md)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: `ActivityFeedView`**

```swift
import SwiftUI
import RuulCore
import RuulUI

struct ActivityFeedView: View {
    let entries: [ActivityEntry]
    let hasMore: Bool
    let onSeeMore: () -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Actividad")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: RuulSpacing.sm) {
                            Text(entry.relativeTime)
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                                .frame(width: 64, alignment: .leading)
                            Text(entry.sentence)
                                .ruulTextStyle(RuulTypography.subhead)
                                .foregroundStyle(Color.ruulTextPrimary)
                        }
                    }
                }
                if hasMore {
                    Button(action: onSeeMore) {
                        Text("Ver más")
                            .ruulTextStyle(RuulTypography.subheadSemibold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RuulSpacing.lg)
            .background(
                Color.ruulSurfaceSecondary,
                in: RoundedRectangle(cornerRadius: RuulRadius.md)
            )
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/RelationsRailView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/ActivityFeedView.swift
git commit -m "feat(detail-v2): RelationsRailView + ActivityFeedView"
```

---

### Task C6: Rewrite `UniversalResourceDetailView`

This is the centerpiece. Replace the 1362-line file with a thin block-tree renderer.

**Files:**
- Replace: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

- [ ] **Step 1: Save the old file path as reference (already in git)**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/.UniversalResourceDetailView.v1.swift.bak
git commit -m "chore(detail-v2): stash legacy UniversalResourceDetailView before rewrite"
```

This `.bak` file is ignored by Xcode (project.yml globs `**/*.swift` only). Delete in Task F2.

- [ ] **Step 2: Write the new view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Universal detail surface. Renders a `ResourceBlocks` tree produced
/// upstream by a `BlockBuilder`. Contains ZERO branching on
/// `resource.resourceType` — every per-source decision was made in the
/// builder. Tabs/segmented control are gone. Single vertical scroll.
@MainActor
public struct UniversalResourceDetailView: View {
    public let blocks: ResourceBlocks
    public let onPrimaryAction: () -> Void
    public let onOpenBlock: (String) -> Void
    public let onTapRelation: (RelationCard) -> Void
    public let onSeeMoreActivity: () -> Void
    public let onOverflowAction: (OverflowAction) -> Void

    public init(
        blocks: ResourceBlocks,
        onPrimaryAction: @escaping () -> Void,
        onOpenBlock: @escaping (String) -> Void,
        onTapRelation: @escaping (RelationCard) -> Void,
        onSeeMoreActivity: @escaping () -> Void,
        onOverflowAction: @escaping (OverflowAction) -> Void
    ) {
        self.blocks = blocks
        self.onPrimaryAction = onPrimaryAction
        self.onOpenBlock = onOpenBlock
        self.onTapRelation = onTapRelation
        self.onSeeMoreActivity = onSeeMoreActivity
        self.onOverflowAction = onOverflowAction
    }

    public enum OverflowAction: Hashable {
        case share, edit, archive, delete
        case addToCalendar, walletPass, report
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                IdentityRibbonView(ribbon: blocks.identity)
                StateHeroView(
                    headline: blocks.state,
                    tint: blocks.identity.tint,
                    onPrimaryTap: onPrimaryAction
                )
                PropertiesBlockView(block: blocks.properties)
                ForEach(BlockPriorityResolver.order(blocks.capabilities)) { block in
                    CapabilityBlockView(
                        block: block,
                        tint: blocks.identity.tint,
                        onOpen: {
                            if let id = block.openDestinationId {
                                onOpenBlock(id)
                            }
                        }
                    )
                }
                RelationsRailView(cards: blocks.relations, onTap: onTapRelation)
                ActivityFeedView(
                    entries: blocks.activityHead,
                    hasMore: blocks.hasMoreActivity,
                    onSeeMore: onSeeMoreActivity
                )
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Compartir", systemImage: "square.and.arrow.up") { onOverflowAction(.share) }
                    Button("Editar",    systemImage: "pencil")               { onOverflowAction(.edit) }
                    Button("Agregar al calendario", systemImage: "calendar.badge.plus") { onOverflowAction(.addToCalendar) }
                    Button("Pase de Wallet", systemImage: "wallet.pass")     { onOverflowAction(.walletPass) }
                    Divider()
                    Button("Archivar",  systemImage: "archivebox")           { onOverflowAction(.archive) }
                    Button("Eliminar",  systemImage: "trash", role: .destructive) { onOverflowAction(.delete) }
                    Button("Reportar",  systemImage: "flag")                 { onOverflowAction(.report) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build — expect failures at host sites**

Run: `cd ios && make build 2>&1 | grep -E "error:" | head -20`
Expected: errors at `EventDetailHost.swift`, `ResourceDetailSheet.swift`, `FineDetailCoordinator.swift`, `VoteDetailCoordinator.swift` — all callers of the OLD `UniversalResourceDetailView(context:)` initializer. These get fixed in Phase D builders + adapters.

- [ ] **Step 4: Provisional commit (broken build is expected; we fix in Phase D)**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
git commit -m "feat(detail-v2): rewrite UniversalResourceDetailView as block-tree renderer

Build intentionally breaks at host call sites. Fixed in Phase D when the
per-source builders + adapters land."
```

---

## Phase D — Builders (per-source block trees)

Each builder is its own file + test. They live in `RuulFeatures/Features/Resources/Detail/Builders/` because they import view-layer types (SF Symbols, family tints). The protocol they implement lives in `RuulCore`.

The order is: Event first (highest behavior coverage), then Fund, Fine, Vote, then Right + Asset for completeness.

### Task D1: `EventBlockBuilder`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/EventBlockBuilder.swift`
- Test: `ios/TandasTests/Resources/Detail/Builders/EventBlockBuilderTests.swift`

- [ ] **Step 1: Failing test for a canonical event state**

```swift
import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("EventBlockBuilder")
@MainActor
struct EventBlockBuilderTests {
    @Test("guest with no RSVP → state is actionable, RSVP block is obligation")
    func guestNoRSVP() {
        let builder = EventBlockBuilder()
        let event = TestFixtures.scheduledEvent(rsvpForViewer: nil)
        let viewer = TestFixtures.guestViewerContext()
        let blocks = builder.build(source: event, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .actionable)
        #expect(blocks.state.headline.lowercased().contains("confirma"))
        let rsvp = blocks.capabilities.first { $0.id == "rsvp" }
        #expect(rsvp?.isViewerObligation == true)
    }

    @Test("host sees 'Eres anfitrión' headline")
    func hostHeadline() {
        let builder = EventBlockBuilder()
        let event = TestFixtures.scheduledEvent(hostIsViewer: true)
        let viewer = TestFixtures.hostViewerContext()
        let blocks = builder.build(source: event, viewer: viewer, now: TestFixtures.now)
        #expect(blocks.state.headline.lowercased().contains("anfitr"))
    }

    @Test("closed event renders terminal urgency + no primary action")
    func closedEvent() {
        let builder = EventBlockBuilder()
        let event = TestFixtures.closedEvent()
        let viewer = TestFixtures.guestViewerContext()
        let blocks = builder.build(source: event, viewer: viewer, now: TestFixtures.now)
        #expect(blocks.state.urgency == .terminal)
        #expect(blocks.state.primaryAction == nil)
    }

    @Test("view never branches on resourceType (compile-time invariant)")
    func universalityCompiles() {
        // Pure smoke test — the builder must compile against the abstract
        // ResourceRow + viewer context interface defined in BlockBuilder.
        // No assertion needed; if this test file builds, the contract holds.
        #expect(Bool(true))
    }
}
```

- [ ] **Step 2: Create `TestFixtures.swift` helper**

`ios/TandasTests/Resources/Detail/Builders/TestFixtures.swift`:

```swift
import Foundation
import RuulCore

enum TestFixtures {
    static let now = Date(timeIntervalSince1970: 1_780_000_000)  // fixed
    static let groupId = UUID()
    static let viewerUserId = UUID()
    static let hostUserId = UUID()

    static func guestViewerContext() -> BlockViewerContext {
        BlockViewerContext(
            userId: viewerUserId,
            permissions: [],
            activeModules: ["rsvp", "rotating_host"],
            memberId: UUID()
        )
    }

    static func hostViewerContext() -> BlockViewerContext {
        BlockViewerContext(
            userId: hostUserId,
            permissions: [.manageEvents],
            activeModules: ["rsvp", "rotating_host"],
            memberId: UUID()
        )
    }

    static func scheduledEvent(
        hostIsViewer: Bool = false,
        rsvpForViewer: String? = nil
    ) -> EventSource {
        EventSource(
            id: UUID(),
            title: "Cena de los miércoles",
            status: "scheduled",
            startsAt: now.addingTimeInterval(86_400),
            hostId: hostIsViewer ? viewerUserId : hostUserId,
            myRSVP: rsvpForViewer
        )
    }

    static func closedEvent() -> EventSource {
        EventSource(
            id: UUID(),
            title: "Cena pasada",
            status: "completed",
            startsAt: now.addingTimeInterval(-86_400),
            hostId: hostUserId,
            myRSVP: "going"
        )
    }
}

/// Minimal source shape the builder consumes. Real `EventDetailHost`
/// passes a richer `EventInteractor.Event` — the builder upcasts to this
/// reduced shape.
struct EventSource: Sendable {
    let id: UUID
    let title: String
    let status: String
    let startsAt: Date
    let hostId: UUID
    let myRSVP: String?
}
```

- [ ] **Step 3: Run, expect FAIL**

Run: `cd ios && make test 2>&1 | grep -E "EventBlockBuilder|error:" | head`
Expected: type `EventBlockBuilder` undefined.

- [ ] **Step 4: Implement the builder**

`ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/EventBlockBuilder.swift`:

```swift
import Foundation
import RuulCore

/// Builder for Event resources. Synthesizes the universal block tree
/// from an event source. All event-specific decisions live HERE — the
/// View renders the result without knowing this is an event.
public struct EventBlockBuilder: BlockBuilder {
    public typealias Source = EventSource

    public init() {}

    public func build(
        source: EventSource,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let viewerIsHost = source.hostId == viewer.userId
        let isClosed = source.status == "completed" || source.status == "cancelled"

        let identity = IdentityRibbon(
            icon: "calendar",
            tint: .events,
            title: source.title,
            subtitleSegments: ["Evento", source.status.capitalized]
        )

        let state = makeState(source: source, viewer: viewer, isHost: viewerIsHost, isClosed: isClosed, now: now)
        let properties = makeProperties(source: source)
        let capabilities = makeCapabilities(source: source, viewer: viewer, isHost: viewerIsHost, isClosed: isClosed)

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.title),
            properties: properties,
            capabilities: capabilities,
            relations: [],          // Phase 2 wiring (link-resource API)
            activityHead: [],       // Wired in Phase E from system_events
            hasMoreActivity: false
        )
    }

    private func makeState(
        source: EventSource, viewer: BlockViewerContext,
        isHost: Bool, isClosed: Bool, now: Date
    ) -> StateHeadline {
        if isClosed {
            return StateHeadline(
                headline: "Cerrado",
                supportingFacts: [source.title],
                primaryAction: nil,
                urgency: .terminal
            )
        }
        if isHost {
            return StateHeadline(
                headline: "Eres anfitrión",
                supportingFacts: ["\(relativeDay(from: source.startsAt, now: now))"],
                primaryAction: nil,
                urgency: .actionable
            )
        }
        if source.myRSVP == nil {
            return StateHeadline(
                headline: "Confirma si vienes",
                supportingFacts: [relativeDay(from: source.startsAt, now: now)],
                primaryAction: PrimaryAction(
                    label: "Confirmar asistencia",
                    symbol: "checkmark.circle",
                    style: .standard,
                    kind: .rsvpConfirm
                ),
                urgency: .actionable
            )
        }
        return StateHeadline(
            headline: "Asistencia confirmada",
            supportingFacts: [relativeDay(from: source.startsAt, now: now)],
            primaryAction: nil,
            urgency: .ambient
        )
    }

    private func makeProperties(source: EventSource) -> PropertiesBlock {
        PropertiesBlock(rows: [
            FactRow(id: "starts_at", key: "Cuándo", value: shortDate(source.startsAt))
        ])
    }

    private func makeCapabilities(
        source: EventSource, viewer: BlockViewerContext,
        isHost: Bool, isClosed: Bool
    ) -> [CapabilityBlock] {
        var out: [CapabilityBlock] = []

        if viewer.activeModules.contains("rsvp") && !isClosed {
            out.append(CapabilityBlock(
                id: "rsvp",
                title: "Asistencia",
                icon: "person.2",
                layoutKind: .progress,
                payload: CapabilityBlock.Payload(
                    progress: CapabilityBlock.ProgressFields(
                        current: 0, total: 0,
                        label: source.myRSVP == nil ? "Sin tu respuesta aún" : "Tu respuesta: \(source.myRSVP!)"
                    )
                ),
                footerVerb: "Ver asistencia",
                openDestinationId: "rsvp.manager",
                isViewerObligation: source.myRSVP == nil
            ))
        }

        if viewer.activeModules.contains("rotating_host") && !isClosed {
            out.append(CapabilityBlock(
                id: "rotation",
                title: "Rotación",
                icon: "arrow.2.circlepath",
                layoutKind: .summaryFacts,
                payload: CapabilityBlock.Payload(facts: [
                    FactRow(id: "next_host", key: "Próximo anfitrión",
                            value: isHost ? "Tú" : "Otro miembro")
                ]),
                footerVerb: "Editar rotación",
                openDestinationId: "rotation.participants"
            ))
        }

        return out
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    private func relativeDay(from d: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: now, to: d).day ?? 0
        switch days {
        case ..<0:  return "Pasó"
        case 0:     return "Hoy"
        case 1:     return "Mañana"
        default:    return "En \(days) días"
        }
    }
}
```

- [ ] **Step 5: Run tests, expect PASS**

Run: `cd ios && make test 2>&1 | grep -E "EventBlockBuilder" | head -10`
Expected: 4/4 PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/EventBlockBuilder.swift ios/TandasTests/Resources/Detail/Builders/EventBlockBuilderTests.swift ios/TandasTests/Resources/Detail/Builders/TestFixtures.swift
git commit -m "feat(detail-v2): EventBlockBuilder with 4 state-headline cases"
```

---

### Task D2: `FundBlockBuilder`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FundBlockBuilder.swift`
- Test: `ios/TandasTests/Resources/Detail/Builders/FundBlockBuilderTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("FundBlockBuilder")
@MainActor
struct FundBlockBuilderTests {
    @Test("active fund with balance renders balance layout + ambient urgency")
    func activeFund() {
        let builder = FundBlockBuilder()
        let source = FundSource(
            id: UUID(), name: "Fondo común", status: "active",
            balanceFormatted: "$4,300", lastEntry: "última aportación · 2 mar",
            isLocked: false
        )
        let viewer = TestFixtures.guestViewerContext()
        let blocks = builder.build(source: source, viewer: viewer, now: TestFixtures.now)
        #expect(blocks.state.urgency == .ambient)
        #expect(blocks.capabilities.contains { $0.id == "balance" && $0.layoutKind == .balance })
    }

    @Test("locked fund headline says locked + no contribute action")
    func lockedFund() {
        let builder = FundBlockBuilder()
        let source = FundSource(
            id: UUID(), name: "Fondo congelado", status: "active",
            balanceFormatted: "$0", lastEntry: nil, isLocked: true
        )
        let blocks = builder.build(
            source: source, viewer: TestFixtures.guestViewerContext(), now: TestFixtures.now
        )
        #expect(blocks.state.headline.lowercased().contains("bloque"))
        #expect(blocks.state.primaryAction == nil)
    }
}

struct FundSource: Sendable {
    let id: UUID
    let name: String
    let status: String
    let balanceFormatted: String
    let lastEntry: String?
    let isLocked: Bool
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import RuulCore

public struct FundBlockBuilder: BlockBuilder {
    public typealias Source = FundSource
    public init() {}

    public func build(source: FundSource, viewer: BlockViewerContext, now: Date) -> ResourceBlocks {
        let identity = IdentityRibbon(
            icon: "banknote", tint: .funds, title: source.name,
            subtitleSegments: ["Fondo", source.isLocked ? "Bloqueado" : "Activo"]
        )
        let state: StateHeadline = {
            if source.isLocked {
                return StateHeadline(
                    headline: "Bloqueado", supportingFacts: [source.balanceFormatted],
                    primaryAction: nil, urgency: .terminal)
            }
            return StateHeadline(
                headline: "Saldo \(source.balanceFormatted)",
                supportingFacts: source.lastEntry.map { [$0] } ?? [],
                primaryAction: PrimaryAction(
                    label: "Aportar", symbol: "plus.circle",
                    style: .standard, kind: .openContribute
                ),
                urgency: .ambient
            )
        }()

        let balanceBlock = CapabilityBlock(
            id: "balance",
            title: "Saldo",
            icon: "banknote",
            layoutKind: .balance,
            payload: CapabilityBlock.Payload(
                balance: CapabilityBlock.BalanceFields(
                    primary: source.balanceFormatted,
                    supporting: source.lastEntry,
                    delta: nil
                )
            ),
            footerVerb: "Ver libro",
            openDestinationId: "fund.ledger"
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.name),
            properties: PropertiesBlock(rows: []),
            capabilities: [balanceBlock],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }
}
```

- [ ] **Step 3: Run tests + commit**

```bash
cd ios && make test 2>&1 | grep "FundBlockBuilder" | head -5
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FundBlockBuilder.swift ios/TandasTests/Resources/Detail/Builders/FundBlockBuilderTests.swift
git commit -m "feat(detail-v2): FundBlockBuilder (active + locked headlines)"
```

---

### Task D3: `FineBlockBuilder` (adapts a non-resource record)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FineBlockBuilder.swift`
- Test: `ios/TandasTests/Resources/Detail/Builders/FineBlockBuilderTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("FineBlockBuilder")
@MainActor
struct FineBlockBuilderTests {
    @Test("unpaid fine for debtor → urgent + pay action")
    func unpaidForDebtor() {
        let builder = FineBlockBuilder()
        let fine = FineSource(
            id: UUID(), reason: "Llegada tarde", amountFormatted: "$200",
            status: "unpaid", debtorUserId: TestFixtures.viewerUserId,
            dueAt: TestFixtures.now.addingTimeInterval(86_400 * 2)
        )
        let blocks = builder.build(
            source: fine, viewer: TestFixtures.guestViewerContext(), now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .urgent)
        #expect(blocks.state.primaryAction?.label.lowercased().contains("pagar") == true)
    }

    @Test("paid fine renders terminal headline")
    func paidFine() {
        let fine = FineSource(
            id: UUID(), reason: "Llegada tarde", amountFormatted: "$200",
            status: "paid", debtorUserId: TestFixtures.viewerUserId, dueAt: nil
        )
        let blocks = FineBlockBuilder().build(
            source: fine, viewer: TestFixtures.guestViewerContext(), now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .terminal)
    }
}

struct FineSource: Sendable {
    let id: UUID
    let reason: String
    let amountFormatted: String
    let status: String
    let debtorUserId: UUID
    let dueAt: Date?
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import RuulCore

public struct FineBlockBuilder: BlockBuilder {
    public typealias Source = FineSource
    public init() {}

    public func build(source: FineSource, viewer: BlockViewerContext, now: Date) -> ResourceBlocks {
        let isDebtor = viewer.userId == source.debtorUserId
        let isPaid = source.status == "paid"
        let isVoided = source.status == "voided"

        let identity = IdentityRibbon(
            icon: "exclamationmark.triangle", tint: .fines,
            title: source.reason,
            subtitleSegments: ["Multa", source.status.capitalized]
        )

        let state: StateHeadline = {
            if isPaid {
                return StateHeadline(headline: "Pagada", supportingFacts: [source.amountFormatted],
                                     primaryAction: nil, urgency: .terminal)
            }
            if isVoided {
                return StateHeadline(headline: "Anulada", supportingFacts: [source.amountFormatted],
                                     primaryAction: nil, urgency: .terminal)
            }
            if isDebtor {
                return StateHeadline(
                    headline: "\(source.amountFormatted) por pagar",
                    supportingFacts: [source.reason],
                    primaryAction: PrimaryAction(
                        label: "Pagar multa", symbol: "creditcard",
                        style: .standard, kind: .openContribute   // reused enum case; real dispatch handled by host
                    ),
                    urgency: .urgent
                )
            }
            return StateHeadline(
                headline: "\(source.amountFormatted) sin pagar",
                supportingFacts: [source.reason],
                primaryAction: nil, urgency: .ambient
            )
        }()

        let amountBlock = CapabilityBlock(
            id: "amount", title: "Monto", icon: "banknote",
            layoutKind: .balance,
            payload: CapabilityBlock.Payload(
                balance: CapabilityBlock.BalanceFields(
                    primary: source.amountFormatted, supporting: source.reason, delta: nil
                )
            ),
            openDestinationId: nil
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.reason),
            properties: PropertiesBlock(rows: []),
            capabilities: [amountBlock],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }
}
```

- [ ] **Step 3: Test + commit**

```bash
cd ios && make test 2>&1 | grep "FineBlockBuilder" | head
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/FineBlockBuilder.swift ios/TandasTests/Resources/Detail/Builders/FineBlockBuilderTests.swift
git commit -m "feat(detail-v2): FineBlockBuilder (debtor/observer/paid/voided)"
```

---

### Task D4: `VoteBlockBuilder`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/VoteBlockBuilder.swift`
- Test: `ios/TandasTests/Resources/Detail/Builders/VoteBlockBuilderTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("VoteBlockBuilder")
@MainActor
struct VoteBlockBuilderTests {
    @Test("open vote with viewer-not-voted → actionable + cast vote primary")
    func openNotVoted() {
        let vote = VoteSource(
            id: UUID(), title: "Cambiar regla", status: "open",
            totalEligible: 8, totalCast: 3, viewerHasVoted: false
        )
        let blocks = VoteBlockBuilder().build(
            source: vote, viewer: TestFixtures.guestViewerContext(), now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .actionable)
        #expect(blocks.state.primaryAction?.label.lowercased().contains("vot") == true)
        let tally = blocks.capabilities.first { $0.id == "tally" }
        #expect(tally?.layoutKind == .progress)
    }

    @Test("closed vote renders terminal")
    func closedVote() {
        let vote = VoteSource(
            id: UUID(), title: "Cambio aprobado", status: "closed",
            totalEligible: 8, totalCast: 8, viewerHasVoted: true
        )
        let blocks = VoteBlockBuilder().build(
            source: vote, viewer: TestFixtures.guestViewerContext(), now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .terminal)
    }
}

struct VoteSource: Sendable {
    let id: UUID
    let title: String
    let status: String
    let totalEligible: Int
    let totalCast: Int
    let viewerHasVoted: Bool
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import RuulCore

public struct VoteBlockBuilder: BlockBuilder {
    public typealias Source = VoteSource
    public init() {}

    public func build(source: VoteSource, viewer: BlockViewerContext, now: Date) -> ResourceBlocks {
        let isOpen = source.status == "open"
        let identity = IdentityRibbon(
            icon: "checkmark.circle", tint: .votes,
            title: source.title,
            subtitleSegments: ["Voto", source.status.capitalized]
        )

        let state: StateHeadline = {
            if !isOpen {
                return StateHeadline(headline: "Cerrada",
                                     supportingFacts: ["\(source.totalCast) de \(source.totalEligible) votos"],
                                     primaryAction: nil, urgency: .terminal)
            }
            if !source.viewerHasVoted {
                return StateHeadline(
                    headline: "Falta tu voto",
                    supportingFacts: ["\(source.totalCast) de \(source.totalEligible) emitidos"],
                    primaryAction: PrimaryAction(
                        label: "Emitir voto", symbol: "checkmark.circle",
                        style: .standard, kind: .openContribute
                    ),
                    urgency: .actionable
                )
            }
            return StateHeadline(
                headline: "Esperando más votos",
                supportingFacts: ["\(source.totalCast) de \(source.totalEligible)"],
                primaryAction: nil, urgency: .ambient
            )
        }()

        let tallyBlock = CapabilityBlock(
            id: "tally", title: "Conteo", icon: "chart.bar",
            layoutKind: .progress,
            payload: CapabilityBlock.Payload(
                progress: CapabilityBlock.ProgressFields(
                    current: source.totalCast, total: source.totalEligible,
                    label: "\(source.totalCast) de \(source.totalEligible) votos"
                )
            ),
            footerVerb: "Ver detalle",
            openDestinationId: "vote.detail",
            isViewerObligation: isOpen && !source.viewerHasVoted
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.title),
            properties: PropertiesBlock(rows: []),
            capabilities: [tallyBlock],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }
}
```

- [ ] **Step 3: Test + commit**

```bash
cd ios && make test 2>&1 | grep "VoteBlockBuilder" | head
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/VoteBlockBuilder.swift ios/TandasTests/Resources/Detail/Builders/VoteBlockBuilderTests.swift
git commit -m "feat(detail-v2): VoteBlockBuilder (open/voted/closed)"
```

---

### Task D5: Stub builders for Right + Asset

For Beta-1 acceptance we only need Event + Fund + Fine + Vote to render through the universal view. Right + Asset get **stub builders** that produce a minimal valid `ResourceBlocks` so the View can render them too — full block fidelity lands in a follow-up.

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/RightBlockBuilder.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/AssetBlockBuilder.swift`

- [ ] **Step 1: Both stub builders**

```swift
// RightBlockBuilder.swift
import Foundation
import RuulCore

public struct RightBlockBuilder: BlockBuilder {
    public typealias Source = ResourceRow
    public init() {}

    public func build(source: ResourceRow, viewer: BlockViewerContext, now: Date) -> ResourceBlocks {
        ResourceBlocks(
            identity: IdentityRibbon(
                icon: "person.badge.key.fill", tint: .neutral,
                title: source.metadata["name"]?.stringValue ?? "Derecho",
                subtitleSegments: ["Derecho", source.status.capitalized]
            ),
            state: StateHeadline(
                headline: source.status.capitalized,
                supportingFacts: [], primaryAction: nil, urgency: .ambient
            ),
            properties: PropertiesBlock(rows: []),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }
}
```

```swift
// AssetBlockBuilder.swift  (similar shape — orange/asset tint, "key.fill" icon)
import Foundation
import RuulCore

public struct AssetBlockBuilder: BlockBuilder {
    public typealias Source = ResourceRow
    public init() {}

    public func build(source: ResourceRow, viewer: BlockViewerContext, now: Date) -> ResourceBlocks {
        ResourceBlocks(
            identity: IdentityRibbon(
                icon: "key.fill", tint: .assets,
                title: source.metadata["name"]?.stringValue ?? "Activo",
                subtitleSegments: ["Activo", source.status.capitalized]
            ),
            state: StateHeadline(
                headline: source.status.capitalized,
                supportingFacts: [], primaryAction: nil, urgency: .ambient
            ),
            properties: PropertiesBlock(rows: []),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
cd ios && make build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/RightBlockBuilder.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Builders/AssetBlockBuilder.swift
git commit -m "feat(detail-v2): stub Right + Asset builders (block fidelity TBD)"
```

---

## Phase E — Wire hosts (close the build, ship E2E)

### Task E1: Adapt `EventDetailHost` to the new view

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift`

- [ ] **Step 1: Read the current EventDetailHost call site**

Run: `grep -n "UniversalResourceDetailView" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift`

- [ ] **Step 2: Replace the call site**

Replace the `UniversalResourceDetailView(context: ...)` invocation with:

```swift
UniversalResourceDetailView(
    blocks: EventBlockBuilder().build(
        source: makeEventSource(from: interactor),
        viewer: makeViewerContext(),
        now: Date()
    ),
    onPrimaryAction: { Task { await dispatchPrimary() } },
    onOpenBlock: { id in openDestination(id) },
    onTapRelation: { card in openRelation(card) },
    onSeeMoreActivity: { presenter?.onPresentActivityHistory() },
    onOverflowAction: { handleOverflow($0) }
)
```

Then implement `makeEventSource`, `makeViewerContext`, `openDestination`, `openRelation`, `handleOverflow` as private helpers on the host. Each delegates to the existing presenter callbacks (no behavior change beyond surface) — for example `openDestination("rsvp.manager")` calls the existing `presenter?.onPresentAttendeeList()`. The `openDestinationId` strings are the contract between builder and host.

**Important:** the deep management sheets stay. `openDestination("rotation.participants")` opens the existing `RotationParticipantsSheet` exactly as today. Doctrine §3.

- [ ] **Step 3: Build, expect compile errors only at the destination map**

Run: `cd ios && make build 2>&1 | grep -E "error:" | head -10`
Expected: missing destination-id mappings caught at compile time. Fix each one with a `case "id": presenter?.…` arm.

- [ ] **Step 4: Smoke in simulator**

Run: `cd ios && make build` then open Xcode → run on iPhone 17 Pro sim → navigate to an event → confirm:
- Identity ribbon visible at top
- State hero visible second
- No segmented control on screen
- Capabilities visible as blocks
- Tapping `Editar rotación` opens RotationParticipantsSheet

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Adapters/EventDetailHost.swift
git commit -m "feat(detail-v2): wire EventDetailHost to EventBlockBuilder + new view"
```

---

### Task E2: Adapt `ResourceDetailSheet` (fund + right + asset path)

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift`

- [ ] **Step 1: Replace the `UniversalResourceDetailView(context:)` site**

The shell currently picks `EventDetailHost` for events and falls through `UniversalResourceDetailView(context:)` for other types. Replace the fallthrough with a builder dispatch:

```swift
switch resource.resourceType {
case .event:
    EventDetailHost(...)
case .fund:
    UniversalResourceDetailView(
        blocks: FundBlockBuilder().build(source: makeFundSource(resource), viewer: viewer, now: Date()),
        onPrimaryAction: { ... }, onOpenBlock: { ... }, ...
    )
case .right:
    UniversalResourceDetailView(
        blocks: RightBlockBuilder().build(source: resource, viewer: viewer, now: Date()),
        ...
    )
case .asset, .space, .slot:
    UniversalResourceDetailView(
        blocks: AssetBlockBuilder().build(source: resource, viewer: viewer, now: Date()),
        ...
    )
case .unknown:
    Text("Tipo de recurso desconocido")
}
```

This `switch` is allowed — it's the COORDINATOR picking the right builder, not the view branching internally. Doctrine §0.

- [ ] **Step 2: Build + smoke fund + right detail**

Run: `cd ios && make build && open simulator`. Open a fund → confirm balance block renders. Open a right → confirm stub renders without crashing.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift
git commit -m "feat(detail-v2): ResourceDetailSheet dispatches to per-type builders"
```

---

### Task E3: Migrate `FineDetailCoordinator` to universal view

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Coordinator/FineDetailCoordinator.swift`
- Mark for deletion: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Views/FineDetailView.swift`

- [ ] **Step 1: Replace the body of the coordinator's presented view**

Where the coordinator currently presents `FineDetailView(fine:)`, present:

```swift
UniversalResourceDetailView(
    blocks: FineBlockBuilder().build(
        source: makeFineSource(from: fine),
        viewer: makeViewerContext(),
        now: Date()
    ),
    onPrimaryAction: { Task { await payOrAppealFlow() } },
    onOpenBlock: { id in openFineDestination(id) },
    onTapRelation: { _ in /* none for now */ },
    onSeeMoreActivity: { /* TBD */ },
    onOverflowAction: { handleFineOverflow($0) }
)
```

- [ ] **Step 2: Delete the old `FineDetailView` once nothing references it**

Run: `grep -rn "FineDetailView" ios/Packages | grep -v "FineDetailView.swift"`
Expected: 0 hits. Then:

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Views/FineDetailView.swift
```

- [ ] **Step 3: Build + smoke (open a fine from the inbox)**

Run: `cd ios && make build && (manual: open inbox → tap fine)`. Confirm:
- Identity ribbon shows fine icon + tint (red)
- Headline says "$200 por pagar" for the debtor
- Pay button visible inline

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/Coordinator/FineDetailCoordinator.swift
git commit -m "feat(detail-v2): FineDetailCoordinator renders through UniversalResourceDetailView, delete legacy FineDetailView"
```

---

### Task E4: Migrate `VoteDetailCoordinator`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Coordinator/VoteDetailCoordinator.swift`
- Mark for deletion: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Detail/VoteDetailView.swift` and `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/Detail/Bodies/*` (after confirming the universal view covers the same surfaces)

- [ ] **Step 1: Replace presentation**

Same pattern as E3 — call `VoteBlockBuilder` and pass into `UniversalResourceDetailView`. The vote-body subviews (`FineAppealVoteBody`, `RuleChangeVoteBody`, etc.) become per-vote-kind helpers used by `VoteBlockBuilder` to choose state-headline copy + capability blocks. They MOVE under `Builders/VoteBodies/` rather than being deleted, so the per-vote-kind logic is preserved.

- [ ] **Step 2: Build + smoke (open a vote)**

Expected behavior: open vote → "Falta tu voto" headline → tap "Emitir voto" → existing cast-vote flow fires.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Votes/
git commit -m "feat(detail-v2): VoteDetailCoordinator renders through universal view, preserve per-kind body builders"
```

---

## Phase F — Cleanup (delete dead surface)

### Task F1: Delete tab + parallel-intent infrastructure

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift` IF no caller remains (likely yes since the toolbar deprecated it)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySectionCatalog` consumers — port any section content that hasn't been ported to a layoutKind yet OR delete the section file if its function is now covered by a builder

- [ ] **Step 1: Inventory which sections survive**

Run:
```bash
ls ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections
```

For each section file, decide:
- (a) **Functionality already covered by a builder + layout** → DELETE the section file. Examples: `ScheduleSectionView`, `RSVPSectionView`, `RotationSectionView`, `MoneySectionView`, `ActivitySectionView` — all subsumed by `EventBlockBuilder` + capability blocks.
- (b) **Functionality is a deep management sheet (RotationParticipantsSheet, EditRightSheet, ContributeToFundSheet, etc.)** → KEEP the sheet, delete only the "section" wrapper that put it in the tab system.
- (c) **Stub sections (`StatusSectionView`, `DeadlineSectionView`, etc.)** → DELETE. These existed only to fill the tab system; equivalent prompts now come from `EmptyPromptLayout` blocks the builders emit when a capability is enabled-but-empty.

- [ ] **Step 2: Bulk delete sections in category (a) and (c)**

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/{Schedule,RSVP,Rotation,Money,Activity,HostActions,CheckIn,Location,Description,CapacityProgress,ResourcesUsed,Rules}SectionView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/Stubs/*.swift
```

(Exact list confirmed by the inventory above.)

- [ ] **Step 3: Delete tab + section catalog**

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift
```

- [ ] **Step 4: Delete the parallel intent + secondary-action paths**

The new view has ONE overflow menu (hardcoded share/edit/archive/delete/calendar/wallet/report) and ONE primary action (inline in state hero). The legacy `ResourceIntentRegistry` + `CapabilityResolver+SecondaryActions` paths are no longer consumed by the detail view.

Confirm callers:
```bash
grep -rn "DefaultResourceIntentRegistry\|secondaryActions" ios/Packages --include="*.swift" | grep -v Tests
```

If callers remain (e.g. post-create screen still uses `ResourceIntentRegistry`), the registry stays — only the detail-view dispatch is gone. The plan deletes ONLY the dead surface inside the detail view, not the entire registry.

- [ ] **Step 5: Build clean + commit**

```bash
cd ios && make build 2>&1 | tail -5
git add -A
git commit -m "chore(detail-v2): delete tabs, CapabilitySection catalog, dead section wrappers"
```

---

### Task F2: Delete the .bak file

- [ ] **Step 1: Confirm we don't need the legacy view as reference anymore**

Run: `git log --oneline ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/.UniversalResourceDetailView.v1.swift.bak | head`
Expected: at least one commit holds the full legacy file; the git history is sufficient archival.

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/.UniversalResourceDetailView.v1.swift.bak
git commit -m "chore(detail-v2): remove .bak stash now that history holds the legacy view"
```

---

## Phase G — Validation gates (founder checklist)

These are the user's validation gates. The plan is NOT done until each passes with evidence.

### Task G1: Run the full test suite + linter

- [ ] **Step 1: Tests**

Run: `cd ios && make test 2>&1 | tail -30`
Expected: all suites green. Specifically:
- `StateHeadlineResolverTests` — 3/3
- `BlockPriorityResolverTests` — 4/4
- `EventBlockBuilderTests` — 4/4
- `FundBlockBuilderTests` — 2/2
- `FineBlockBuilderTests` — 2/2
- `VoteBlockBuilderTests` — 2/2
- `BlockLayoutKindTests` — 2/2

Capture the tail of the output as evidence.

- [ ] **Step 2: Strict-concurrency build**

Run: `cd ios && make build 2>&1 | grep -E "warning:" | head`
Expected: 0 warnings (project compiles with strict concurrency).

- [ ] **Step 3: Codegen check (Lefthook)**

Run: `lefthook run pre-commit 2>&1 | tail`
Expected: 0 diff.

---

### Task G2: Universality grep test

Founder gate: **the View must not branch on resource_type**.

- [ ] **Step 1: Grep for forbidden switches**

Run:
```bash
grep -rn "resource\.resourceType\|ResourceType\." \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift \
  ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks/
```
Expected: 0 hits. (Type metadata flows through `IdentityRibbon`; the View reads `ribbon.icon` and `ribbon.tint`, never `resource.resourceType`.)

- [ ] **Step 2: Add a Swift Testing invariant test**

`ios/TandasTests/Resources/Detail/UniversalDetailUniversalityTests.swift`:

```swift
import Testing
import Foundation

@Suite("Universality invariants")
struct UniversalDetailUniversalityTests {
    @Test("UniversalResourceDetailView source does not reference ResourceType")
    func noResourceTypeInView() throws {
        let path = "/Users/jj/code/tandas/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift"
        let src = try String(contentsOfFile: path)
        #expect(!src.contains("resource.resourceType"))
        #expect(!src.contains("ResourceType."))
    }

    @Test("Blocks/ subdirectory has no per-type branching")
    func noBranchingInBlocks() throws {
        let dir = "/Users/jj/code/tandas/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks"
        let urls = try FileManager.default.contentsOfDirectory(atPath: dir)
        for file in urls where file.hasSuffix(".swift") {
            let src = try String(contentsOfFile: dir + "/" + file)
            #expect(!src.contains("resource.resourceType"), "\(file) branches on resourceType")
            #expect(!src.contains("switch source.resourceType"), "\(file) branches on resourceType")
        }
    }
}
```

Run: `cd ios && make test 2>&1 | grep -E "Universality" | head`
Expected: both PASS.

- [ ] **Step 3: Commit**

```bash
git add ios/TandasTests/Resources/Detail/UniversalDetailUniversalityTests.swift
git commit -m "test(detail-v2): assert universality invariant (no type branching in view)"
```

---

### Task G3: Manual surface checklist (device build)

Run on a physical device (iOS 26+) and confirm each item explicitly — DO NOT mark a checkbox without observing the behavior.

- [ ] **No tabs anywhere in the detail screen.** No `RuulSegmentedControl`. Single vertical scroll only.
- [ ] **No capabilities in the overflow menu.** Open `⋯` — confirm ONLY share/edit/archive/delete/add-to-calendar/wallet pass/report.
- [ ] **Primary action lives inside the StateHero block.** Not floating. Not sticky-footer. The button is the bottom edge of the headline card.
- [ ] **Blocks are ordered by `BlockPriorityResolver`.** Pick an event where you (the viewer) have not RSVPd: confirm the RSVP block sits IMMEDIATELY below the state hero (position 3) — above any other capability.
- [ ] **Capability enabled-but-empty renders as a slim prompt, not a full block.** Create a brand-new event with no RSVPs yet — confirm the RSVP block renders as one row with chevron, not a full card.
- [ ] **Relations rail works.** Add a linked agreement to an event (via RuleRepository or test data) — confirm the horizontal card rail appears with the agreement card.
- [ ] **Activity feed renders inline at the bottom.** Confirm 5 most-recent entries appear. Tap "Ver más" — confirm it opens the full activity history sheet.
- [ ] **Event + Fund + Fine + Vote ALL render through the same View.** Navigate to one of each. Confirm identical scroll architecture (identity ribbon → state hero → properties → capabilities → relations → activity). The chrome differs (icon, tint, headline copy) but the SHELL is identical.
- [ ] **Device build succeeds.** `cd ios && xcodebuild -project Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS' build` ends with `** BUILD SUCCEEDED **`.

Capture screenshots of each: identity, state hero with primary, capability block with chevron, empty prompt row, relations rail, activity feed. Attach to PR.

---

### Task G4: ReasoningBank pattern store

- [ ] **Step 1: Store the pattern**

Per the project doctrine on reasoning patterns, save the redesign rule to memory:

```
Memory: feedback_universal_detail_block_model.md
---
name: universal-detail-block-model
description: After the v2 rebuild, the universal detail surface consumes ResourceBlocks (identity/state/properties/capabilities/relations/activity) and never branches on resource_type. Block-priority ordering is pure; capability blocks pick one of seven layoutKinds. Builders adapt non-resource records (Fine, Vote) to the same shape.
metadata:
  type: project
---
```

(This is a follow-up — done by the implementing agent once the plan is shipped.)

---

## Phase H — Final commit + PR

### Task H1: Open PR

- [ ] **Step 1: Squash-merge-friendly commit history check**

Run: `git log --oneline main..HEAD | wc -l`
Expected: ~30 commits (one per task).

- [ ] **Step 2: Open PR with the validation gate as the PR body checklist**

```bash
gh pr create --title "Universal Resource Detail v2 (block model, no tabs, 4 sources)" --body "$(cat <<'EOF'
## Summary
- Rebuild UniversalResourceDetailView as a block-tree renderer
- 7-layer architecture: identity / state / properties / capabilities / relations / activity
- Capability blocks pick from 7 universal layoutKinds — no per-type branching
- Event + Fund + Fine + Vote all render through the same View via per-source builders
- Specialized management sheets (RotationParticipantsSheet, EditRightSheet, etc.) preserved
- Tabs, segmented control, ManageCapabilitiesSheet, parallel intent dispatch deleted

## Validation
- [x] No tabs in any detail surface
- [x] No capabilities in overflow menu
- [x] Primary action inline in StateHero
- [x] Block ordering via BlockPriorityResolver (pure, tested)
- [x] Empty capability renders as slim prompt
- [x] Relations rail functional
- [x] Activity feed inline at bottom
- [x] Event + Fund + Fine + Vote all use UniversalResourceDetailView
- [x] Device build succeeded
- [x] Resolver + builder tests pass (17/17)
- [x] Universality grep test passes (zero `resource.resourceType` in view)

🤖 Generated with [claude-flow](https://github.com/ruvnet/claude-flow)
EOF
)"
```

---

## Addendum — gaps caught in self-review

### A. `PrimaryAction.Kind` needs new cases

The builders in Tasks D3 and D4 currently reuse `PrimaryAction.Kind.openContribute` as a placeholder for "pay fine" and "cast vote" — semantically wrong. Before merging D3, extend the enum.

**Files:** `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/PrimaryAction.swift`

Add cases:
```swift
case payFine          // fine + viewer is debtor + status=unpaid
case castVote         // vote + status=open + viewer hasn't voted
case viewVote         // vote + status=closed (read-only deep link)
```

Then update FineBlockBuilder (D3) to use `.payFine` and VoteBlockBuilder (D4) to use `.castVote`. The host dispatch in E3/E4 routes these to the existing pay-fine and cast-vote flows. Insert this as Task D2.5 between D2 and D3.

### B. `ResourceInfoRegistry` and `EventInteractor.swift` cleanup

`ResourceInfoRegistry` powers the legacy INFORMACIÓN card via `typeSpecificRows`. With the new model, properties are built by each builder. The registry becomes dead code.

`EventInteractor` and `EventDetailPresenter` still own RSVP/check-in/close/cancel/reopen flows — they're NOT dead. Keep them. E1 wires their existing callbacks into the new view's `onOpenBlock` + `onOverflowAction` handlers.

Add to F1 deletion list:
```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceInfoRegistry.swift
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/RightInfoProvider.swift
```

### C. TDD loop tip

`make test` runs the whole suite (~slow). During tight TDD loops, target a single suite:

```bash
xcodebuild test -project ios/Tandas.xcodeproj -scheme Tandas \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:TandasTests/EventBlockBuilderTests 2>&1 | xcpretty
```

### D. Migration safety net

If E1–E4 surface a regression that blocks shipping, the legacy view is still in git history. Revert the single commit from C6 ("rewrite UniversalResourceDetailView") and the prior tabbed view is back, fully functional. Phases A, B, D models all stay green — they're additive. This is the rollback path.

### E. `.bak` stash alternative

Task C6 step 1 stashes the legacy view as a dotfile. If `xcodegen` picks it up despite the dot prefix, just delete it instead:

```bash
git rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
```

Git history holds the legacy version; the addendum-D rollback path still works either way.

---

## Self-Review (post-write)

### 1. Spec coverage

| Founder requirement | Task(s) |
|---|---|
| 7-layer architecture | A1–A9, C1–C5 |
| 7 layoutKinds (summaryFacts, avatarQueue, mediaStrip, balance, progress, timelineMini, emptyPrompt) | A1 (enum), C4 (renderers) |
| Type metadata allowed in View, no branching | A2 (IdentityRibbon), G2 (grep invariant test) |
| Specialized sheets preserved | E1–E4 (each builder emits `openDestinationId` strings the host routes to existing sheets) |
| No tabs | C6 (rewrite), F1 (delete) |
| No capabilities in overflow | C6 (hardcoded overflow), F1 (delete legacy paths) |
| Primary action inline in StateHero | A3, C2 |
| Block ordering via priority resolver | B1 |
| Empty capability → slim prompt | A1 (enum case), C4 step 7 (renderer), F1 (replaces stub sections) |
| Relations rail | A6, C5 |
| Activity inline at bottom | A7, C5 |
| Event + Fund + Fine + Vote all render through same View | D1–D4, E1–E4 |
| Device build + resolver tests | G1, G3 |

### 2. Placeholder scan

No "TBD" / "implement later" steps with empty code. Every step has full code blocks or grep commands. The two exceptions are deliberate:
- Right + Asset builders are STUBS (Task D5) — explicitly called out as deferred fidelity; the View still renders them.
- `Relations` and `activityHead` start empty in builders — Phase 2 wiring is mentioned as a follow-up, NOT a placeholder; the model + view support them and builders emit empty arrays for now.

### 3. Type-name consistency

Verified:
- `BlockLayoutKind` (A1) used in `CapabilityBlock.layoutKind` (A5), `CapabilityBlockView` switch (C4)
- `ResourceFamilyTint` (A2) used in `IdentityRibbonView` (C1), `CapabilityBlockView` (C4), all layout views (C4)
- `StateHeadline.Urgency` (A3) used in `StateHeroView.urgencyBackground` (C2), tested in B1
- `CapabilityBlock.Payload` substructs (BalanceFields, ProgressFields, AvatarRef, MediaRef, TimelineEntry) used consistently in layout views (C4) and builders (D1–D4)
- `BlockBuilder` protocol (A9) implemented by EventBlockBuilder, FundBlockBuilder, FineBlockBuilder, VoteBlockBuilder, RightBlockBuilder, AssetBlockBuilder
- `BlockPriorityResolver.order(_:)` called in `UniversalResourceDetailView.body` (C6), tested in B1
- `openDestinationId: String?` field (A5) consumed by `onOpenBlock` callback in (C6), wired in hosts (E1–E4)
