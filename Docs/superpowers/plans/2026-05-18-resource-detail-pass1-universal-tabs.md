# Resource Detail Pass 1: Universal Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-scroll `UniversalResourceDetailView` with 5 universal tabs (Overview / Activity / Rules / Connections / Governance), declaratively assigned via a new `tabId` field on `CapabilitySection`, and demote `ManageCapabilitiesSheet` to inline content inside the Governance tab.

**Architecture:** UX-only refactor. `CapabilitySection` gains a `tabId: String` field (default `"overview"`); a new `ResourceDetailTab` enum lists the 5 universal tabs. `UniversalResourceDetailView` renders a persistent identity zone (hero + INFORMACIÓN) above a `RuulSegmentedControl`, then filters the existing catalog sections by selected tab. `ManageCapabilitiesSheet` body is extracted to a reusable `AdvancedCapabilitiesView` consumed by a new `GovernanceTabView`. Zero backend/ontology/engine changes.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI iOS 26+, Swift Testing in `ios/TandasTests/`, `RuulCore` (models + protocols), `RuulFeatures` (views + coordinators), `RuulUI` (DesignSystem).

**Spec:** `docs/superpowers/specs/2026-05-18-resource-detail-intent-refactor-design.md`

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift` | CREATE (~60 L) | Enum of 5 universal tabs + label/symbol metadata |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift` | MODIFY | Add `tabId: String` field with default `"overview"` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/RulesSectionView.swift` | MODIFY | `definition.tabId = "rules"` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ResourcesUsedSectionView.swift` | MODIFY | `definition.tabId = "connections"` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ActivitySectionView.swift` | MODIFY | `definition.tabId = "activity"` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift` | CREATE (~250 L) | Extracted body of ManageCapabilitiesSheet (no NavigationStack wrapper) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift` | MODIFY | Reduce to thin shell wrapping AdvancedCapabilitiesView in NavigationStack + toolbar |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift` | CREATE (~140 L) | Wraps AdvancedCapabilitiesView + (optional) archive action |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift` | MODIFY | Body: hero + INFORMACIÓN + segmented + tab dispatch; drop SettingsSectionView |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailContext.swift` | MODIFY | Drop `onPresentEnableCapability` field + ctor param |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift` | MODIFY | Drop `enableCapabilityPresented` state + `.fullScreenCover` block |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift` | DELETE | Functionality moved to GovernanceTabView |
| `ios/TandasTests/Capabilities/ResourceDetailTabTests.swift` | CREATE | Enum surface tests |
| `ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift` | CREATE | Default + filter tests |

---

## Task 1: Add `tabId` field to `CapabilitySection` (TDD)

**Files:**
- Test: `ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift`:

```swift
import Testing
import SwiftUI
import RuulCore
@testable import RuulFeatures

@Suite("CapabilitySection.tabId")
@MainActor
struct CapabilitySectionTabIdTests {
    @Test("default tabId is 'overview' when not specified")
    func defaultTabIdIsOverview() {
        let section = CapabilitySection(
            id: "test",
            priority: 100,
            isEnabledFor: { _ in true },
            render: { _ in AnyView(EmptyView()) }
        )
        #expect(section.tabId == "overview")
    }

    @Test("explicit tabId is preserved")
    func explicitTabIdPreserved() {
        let section = CapabilitySection(
            id: "test",
            priority: 100,
            tabId: "rules",
            isEnabledFor: { _ in true },
            render: { _ in AnyView(EmptyView()) }
        )
        #expect(section.tabId == "rules")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/CapabilitySectionTabIdTests 2>&1 | tail -30
```

Expected: FAIL — compilation error "Argument passed to call that takes no parameters" or "Value of type 'CapabilitySection' has no member 'tabId'".

- [ ] **Step 3: Add field + default to `CapabilitySection`**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift`, replace the struct body. Add `tabId: String` after `priority`, default `"overview"` in init:

```swift
public struct CapabilitySection: Identifiable {
    public let id: String
    public let priority: Int
    /// Which tab this section renders inside. Default "overview" matches
    /// pre-Pass-1 behavior (everything stacked in one scroll). Sections
    /// that move tabs declare their target explicitly. The string is
    /// matched against `ResourceDetailTab.id`.
    public let tabId: String
    public let isEnabledFor: (Set<String>) -> Bool
    public let isVisibleFor: ((ResourceDetailContext) -> Bool)?
    public let render: (ResourceDetailContext) -> AnyView

    public init(
        id: String,
        priority: Int,
        tabId: String = "overview",
        isEnabledFor: @escaping (Set<String>) -> Bool,
        isVisibleFor: ((ResourceDetailContext) -> Bool)? = nil,
        render: @escaping (ResourceDetailContext) -> AnyView
    ) {
        self.id = id
        self.priority = priority
        self.tabId = tabId
        self.isEnabledFor = isEnabledFor
        self.isVisibleFor = isVisibleFor
        self.render = render
    }
}
```

(The `CapabilitySectionCatalog` class below is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/CapabilitySectionTabIdTests 2>&1 | tail -20
```

Expected: PASS — both tests green.

- [ ] **Step 5: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/CapabilitySection.swift ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift
git commit -m "$(printf 'feat(detail): CapabilitySection gains tabId field (default overview)\n\nPart of Pass 1 universal tabs refactor.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 2: Create `ResourceDetailTab` enum (TDD)

**Files:**
- Test: `ios/TandasTests/Capabilities/ResourceDetailTabTests.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Capabilities/ResourceDetailTabTests.swift`:

```swift
import Testing
@testable import RuulFeatures

@Suite("ResourceDetailTab")
struct ResourceDetailTabTests {
    @Test("allCases is exactly the 5 universal tabs in canonical order")
    func allCasesCanonicalOrder() {
        #expect(ResourceDetailTab.allCases.map(\.rawValue) == [
            "overview", "activity", "rules", "connections", "governance",
        ])
    }

    @Test("labels are Spanish display strings")
    func labelsAreSpanish() {
        #expect(ResourceDetailTab.overview.label == "General")
        #expect(ResourceDetailTab.activity.label == "Actividad")
        #expect(ResourceDetailTab.rules.label == "Reglas")
        #expect(ResourceDetailTab.connections.label == "Conexiones")
        #expect(ResourceDetailTab.governance.label == "Gobierno")
    }

    @Test("id mirrors rawValue")
    func idMirrorsRawValue() {
        for tab in ResourceDetailTab.allCases {
            #expect(tab.id == tab.rawValue)
        }
    }

    @Test("symbol returns non-empty SF Symbol per tab")
    func symbolNonEmpty() {
        for tab in ResourceDetailTab.allCases {
            #expect(!tab.symbol.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/ResourceDetailTabTests 2>&1 | tail -20
```

Expected: FAIL — "cannot find 'ResourceDetailTab' in scope".

- [ ] **Step 3: Create the enum**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift`:

```swift
import Foundation

/// The 5 universal tabs every resource detail screen shows in Pass 1.
/// Per-type tabs (Pass 2) extend this by introducing a `ResourceTabRegistry`
/// that returns ordered tabs per `ResourceType` — the universal 5 stay as
/// the canonical baseline.
///
/// Mapped to sections via `CapabilitySection.tabId`. The string match is
/// `tab.id == section.tabId`. Sections without an explicit tabId default
/// to `.overview`.
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case connections
    case governance

    public var id: String { rawValue }

    /// Spanish label for the segmented control. Kept short ("Gobierno"
    /// not "Gobernanza") so 5 segments fit on iPhone SE width.
    public var label: String {
        switch self {
        case .overview:    return "General"
        case .activity:    return "Actividad"
        case .rules:       return "Reglas"
        case .connections: return "Conexiones"
        case .governance:  return "Gobierno"
        }
    }

    /// SF Symbol used in empty-state cards + (future) per-tab badges.
    /// Not currently rendered inside the segmented control itself —
    /// `RuulSegmentedControl` is label-only.
    public var symbol: String {
        switch self {
        case .overview:    return "doc.text"
        case .activity:    return "clock.arrow.circlepath"
        case .rules:       return "list.bullet.clipboard"
        case .connections: return "link"
        case .governance:  return "shield"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/ResourceDetailTabTests 2>&1 | tail -20
```

Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift ios/TandasTests/Capabilities/ResourceDetailTabTests.swift
git commit -m "$(printf 'feat(detail): ResourceDetailTab enum (5 universal tabs)\n\nPart of Pass 1 universal tabs refactor.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 3: Assign `tabId` on the 3 sections that change tabs (TDD)

**Files:**
- Modify: `ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/RulesSectionView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ResourcesUsedSectionView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ActivitySectionView.swift`

- [ ] **Step 1: Extend the test suite**

Append these tests to `ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift` before the closing `}` of the suite:

```swift
    @Test("RulesSectionView.definition.tabId == rules")
    func rulesSectionTab() {
        #expect(RulesSectionView.definition.tabId == "rules")
    }

    @Test("ResourcesUsedSectionView.definition.tabId == connections")
    func resourcesUsedSectionTab() {
        #expect(ResourcesUsedSectionView.definition.tabId == "connections")
    }

    @Test("ActivitySectionView.definition.tabId == activity")
    func activitySectionTab() {
        #expect(ActivitySectionView.definition.tabId == "activity")
    }

    @Test("a sample default section still reports overview")
    func defaultSectionStillOverview() {
        // RSVPSectionView never declared tabId — must default to "overview"
        #expect(RSVPSectionView.definition.tabId == "overview")
    }
```

- [ ] **Step 2: Run tests to verify the 3 new ones fail**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/CapabilitySectionTabIdTests 2>&1 | tail -25
```

Expected: 3 FAIL (rules/connections/activity tab assertions return "overview"); 1 PASS (RSVP overview default).

- [ ] **Step 3: Assign tabId in RulesSectionView**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/RulesSectionView.swift`, modify the `definition` block:

```swift
    public static let definition = CapabilitySection(
        id: "rules",
        priority: 800,
        tabId: "rules",
        isEnabledFor: { caps in caps.contains("rules") },
        render: { ctx in AnyView(RulesSectionView(context: ctx)) }
    )
```

- [ ] **Step 4: Assign tabId in ResourcesUsedSectionView**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ResourcesUsedSectionView.swift`, modify the `definition` block:

```swift
    public static let definition = CapabilitySection(
        id: "resource_links",
        priority: 850,
        tabId: "connections",
        isEnabledFor: { _ in true },
        isVisibleFor: { ctx in ctx.resource.resourceType == .event },
        render: { ctx in AnyView(ResourcesUsedSectionView(context: ctx)) }
    )
```

- [ ] **Step 5: Assign tabId in ActivitySectionView**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ActivitySectionView.swift`, modify the `definition` block:

```swift
    public static let definition = CapabilitySection(
        id: "activity",
        priority: 900,
        tabId: "activity",
        // Always render — every resource has a history.
        isEnabledFor: { _ in true },
        render: { ctx in AnyView(ActivitySectionView(context: ctx)) }
    )
```

- [ ] **Step 6: Run the suite to verify all green**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TandasTests/CapabilitySectionTabIdTests 2>&1 | tail -20
```

Expected: 6 PASS, 0 FAIL.

- [ ] **Step 7: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/RulesSectionView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ResourcesUsedSectionView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/ActivitySectionView.swift ios/TandasTests/Capabilities/CapabilitySectionTabIdTests.swift
git commit -m "$(printf 'feat(detail): assign tabId to rules/connections/activity sections\n\nRulesSectionView -> rules tab, ResourcesUsedSectionView -> connections,\nActivitySectionView -> activity. All other sections default to overview.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 4: Extract `AdvancedCapabilitiesView` from `ManageCapabilitiesSheet`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift`

- [ ] **Step 1: Create the extracted view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift` — this is the existing `ManageCapabilitiesSheet` body **without** the NavigationStack/toolbar wrapper, so it can be embedded inline inside a tab:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Capability management surface — enable inactive, edit configs, disable
/// enabled, cascade dependency alerts. Body extracted from
/// `ManageCapabilitiesSheet` so it can render inline inside
/// `GovernanceTabView` (no NavigationStack / ruulSheetToolbar wrapper).
///
/// The sheet wrapper still exists for legacy fullScreenCover callers but
/// post-Pass-1 the canonical entry point is the Governance tab.
@MainActor
public struct AdvancedCapabilitiesView: View {
    @Environment(AppState.self) private var app

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let enabled: [ResourceCapability]
    public let onChanged: () -> Void

    @State private var pendingId: String?
    @State private var errorText: String?
    @State private var editingBlock: (block: any CapabilityBlock, config: JSONConfig)?
    @State private var cascadeDisable: CascadeContext?
    @State private var cascadeEnable: CascadeContext?

    private struct CascadeContext: Identifiable {
        let id = UUID()
        let targetId: String
        let related: [String]
    }

    public init(
        resourceId: UUID,
        resourceType: ResourceType,
        enabled: [ResourceCapability],
        onChanged: @escaping () -> Void
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.enabled = enabled
        self.onChanged = onChanged
    }

    private var enabledIds: Set<String> { Set(enabled.map { $0.capabilityBlockId }) }

    private var availableBlocks: [any CapabilityBlock] {
        CapabilityCatalog.v1.blocks(for: resourceType)
            .filter { !enabledIds.contains($0.id) }
    }

    private var enabledBlocks: [(block: any CapabilityBlock, row: ResourceCapability)] {
        enabled.compactMap { row in
            guard let block = CapabilityCatalog.v1.byId[row.capabilityBlockId] else { return nil }
            return (block, row)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
            if !enabledBlocks.isEmpty {
                section(title: "ACTIVAS") {
                    VStack(spacing: 0) {
                        ForEach(enabledBlocks, id: \.block.id) { item in
                            enabledRow(block: item.block, row: item.row)
                            if item.block.id != enabledBlocks.last?.block.id {
                                Divider().background(Color.ruulSeparator).padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
            if !availableBlocks.isEmpty {
                section(title: "DISPONIBLES") {
                    VStack(spacing: 0) {
                        ForEach(availableBlocks, id: \.id) { block in
                            availableRow(block)
                            if block.id != availableBlocks.last?.id {
                                Divider().background(Color.ruulSeparator).padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
            if let errorText {
                Text(errorText)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
            }
        }
        .fullScreenCover(item: editingBinding) { ctx in
            EditCapabilityConfigSheet(
                resourceId: resourceId,
                block: ctx.block,
                initialConfig: ctx.config,
                onSaved: {
                    editingBlock = nil
                    onChanged()
                }
            )
            .environment(app)
        }
        .alert(
            "Esto desactivará también:",
            isPresented: disableAlertBinding,
            presenting: cascadeDisable
        ) { ctx in
            Button("Desactivar todas", role: .destructive) {
                Task { await disableCascade(ctx.targetId, dependents: ctx.related) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { ctx in
            Text(ctx.related.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
        }
        .alert(
            "Activar también:",
            isPresented: enableAlertBinding,
            presenting: cascadeEnable
        ) { ctx in
            Button("Activar todas") {
                Task { await enableCascade(ctx.targetId, missing: ctx.related) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { ctx in
            Text(ctx.related.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func enabledRow(block: any CapabilityBlock, row: ResourceCapability) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.ruulPositive)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(block.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                if !block.optionalFields.isEmpty || !block.requiredFields.isEmpty {
                    Button("Editar configuración", systemImage: "slider.horizontal.3") {
                        editingBlock = (block, row.config)
                    }
                }
                Button("Desactivar", systemImage: "minus.circle", role: .destructive) {
                    let resolver = CapabilityDependencyResolver()
                    let blockers = resolver.dependents(of: block.id, in: enabledIds)
                    if blockers.isEmpty {
                        Task { await disable(block.id) }
                    } else {
                        cascadeDisable = CascadeContext(targetId: block.id, related: blockers)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .disabled(pendingId != nil)
        }
        .padding(RuulSpacing.md)
        .opacity(pendingId == block.id ? 0.4 : 1.0)
    }

    @ViewBuilder
    private func availableRow(_ block: any CapabilityBlock) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: "circle")
                .foregroundStyle(Color.ruulTextTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(block.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                let resolver = CapabilityDependencyResolver()
                let missing = resolver.missingDependencies(of: block.id, in: enabledIds)
                if missing.isEmpty {
                    Task { await enable(block.id) }
                } else {
                    cascadeEnable = CascadeContext(targetId: block.id, related: missing)
                }
            } label: {
                Text("Activar")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            .buttonStyle(.plain)
            .disabled(pendingId != nil)
        }
        .padding(RuulSpacing.md)
        .opacity(pendingId == block.id ? 0.4 : 1.0)
    }

    private var disableAlertBinding: Binding<Bool> {
        Binding(get: { cascadeDisable != nil }, set: { if !$0 { cascadeDisable = nil } })
    }

    private var enableAlertBinding: Binding<Bool> {
        Binding(get: { cascadeEnable != nil }, set: { if !$0 { cascadeEnable = nil } })
    }

    private func disableCascade(_ targetId: String, dependents: [String]) async {
        pendingId = targetId
        errorText = nil
        defer { pendingId = nil }
        do {
            for id in dependents {
                try await app.resourceCapabilityRepo.disable(id, on: resourceId)
            }
            try await app.resourceCapabilityRepo.disable(targetId, on: resourceId)
            onChanged()
        } catch {
            errorText = "No pudimos desactivar todas las capabilities."
        }
    }

    private func enableCascade(_ targetId: String, missing: [String]) async {
        pendingId = targetId
        errorText = nil
        defer { pendingId = nil }
        do {
            for id in missing {
                _ = try await app.resourceCapabilityRepo.enable(id, on: resourceId, config: .empty)
            }
            _ = try await app.resourceCapabilityRepo.enable(targetId, on: resourceId, config: .empty)
            onChanged()
        } catch {
            errorText = "No pudimos activar todas las capabilities."
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
        }
    }

    private var editingBinding: Binding<EditingContext?> {
        Binding(
            get: {
                guard let e = editingBlock else { return nil }
                return EditingContext(block: e.block, config: e.config)
            },
            set: { new in
                if new == nil { editingBlock = nil }
            }
        )
    }

    private func enable(_ blockId: String) async {
        pendingId = blockId
        errorText = nil
        defer { pendingId = nil }
        do {
            _ = try await app.resourceCapabilityRepo.enable(blockId, on: resourceId, config: .empty)
            onChanged()
        } catch {
            errorText = "No pudimos activar esta capability."
        }
    }

    private func disable(_ blockId: String) async {
        pendingId = blockId
        errorText = nil
        defer { pendingId = nil }
        do {
            try await app.resourceCapabilityRepo.disable(blockId, on: resourceId)
            onChanged()
        } catch {
            errorText = "No pudimos desactivar esta capability."
        }
    }
}

/// Wraps the editing context so `fullScreenCover(item:)` can drive it.
private struct EditingContext: Identifiable {
    let block: any CapabilityBlock
    let config: JSONConfig

    var id: String { block.id }
}
```

- [ ] **Step 2: Reduce `ManageCapabilitiesSheet` to a thin shell**

Replace the entire contents of `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift` with:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Sheet wrapper around `AdvancedCapabilitiesView`. Pass-1 deprecated as
/// a primary entry point — the canonical surface is the Governance tab
/// embedding `AdvancedCapabilitiesView` directly. Retained for legacy
/// callers (none expected post-Pass-1 cleanup).
public struct ManageCapabilitiesSheet: View {
    @Environment(AppState.self) private var app

    public let resourceId: UUID
    public let resourceType: ResourceType
    public let enabled: [ResourceCapability]
    public let onChanged: () -> Void

    public init(
        resourceId: UUID,
        resourceType: ResourceType,
        enabled: [ResourceCapability],
        onChanged: @escaping () -> Void
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.enabled = enabled
        self.onChanged = onChanged
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                AdvancedCapabilitiesView(
                    resourceId: resourceId,
                    resourceType: resourceType,
                    enabled: enabled,
                    onChanged: onChanged
                )
                .environment(app)
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Capabilities")
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run:
```
cd ios && xcodebuild build -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/AdvancedCapabilitiesView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift
git commit -m "$(printf 'refactor(detail): extract AdvancedCapabilitiesView from ManageCapabilitiesSheet\n\nThe inline body becomes reusable inside the Governance tab. Sheet shrinks\nto a thin NavigationStack wrapper.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 5: Create `GovernanceTabView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift`

- [ ] **Step 1: Create the tab view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift`:

```swift
import SwiftUI
import RuulCore
import RuulUI

/// Content of the Governance tab. Pass 1 surfaces capability management
/// (formerly behind `ManageCapabilitiesSheet`) inline plus an optional
/// archive action. Pass 2+ adds role/permission summary + rule scope
/// hierarchy preview.
///
/// Loads its own capability list on appear instead of reading from the
/// parent — keeps the tab self-contained and avoids threading caps
/// through `ResourceDetailContext`.
@MainActor
public struct GovernanceTabView: View {
    @Environment(AppState.self) private var app

    public let resource: ResourceRow
    public let onArchive: (() -> Void)?

    @State private var capabilities: [ResourceCapability] = []
    @State private var isLoading: Bool = true

    public init(
        resource: ResourceRow,
        onArchive: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.onArchive = onArchive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
            AdvancedCapabilitiesView(
                resourceId: resource.id,
                resourceType: resource.resourceType,
                enabled: capabilities.filter { $0.enabled },
                onChanged: { Task { await reload() } }
            )

            if let onArchive {
                advancedSection {
                    Button(action: onArchive) {
                        HStack(spacing: RuulSpacing.s2) {
                            Image(systemName: "archivebox")
                                .frame(width: 24)
                            Text("Archivar este recurso")
                                .ruulTextStyle(RuulTypography.body)
                            Spacer()
                        }
                        .foregroundStyle(Color.red)
                        .padding(RuulSpacing.md)
                    }
                    .buttonStyle(.plain)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
                }
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func advancedSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("AVANZADO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            content()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        capabilities = (try? await app.resourceCapabilityRepo.list(resourceId: resource.id)) ?? []
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run:
```
cd ios && xcodebuild build -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/GovernanceTabView.swift
git commit -m "$(printf 'feat(detail): GovernanceTabView wraps AdvancedCapabilitiesView inline\n\nWill be embedded in UniversalResourceDetailView in next task.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 6: Refactor `UniversalResourceDetailView` to use segmented control + tab dispatch

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

Reference for orientation:
- Current body lives at `UniversalResourceDetailView.swift:57-158`
- `catalogSections(idIn:)` helper used for filtering today
- `Self.dynamicSectionIds` is a static list of which sections render in the dynamic block

- [ ] **Step 1: Read the current body block**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift` and locate:
1. `@State private var` declarations (around lines 39-51)
2. `body: some View { ScrollView { VStack { ... } ... } }` (lines 57-158)
3. `catalogSections(idIn:)` helper (search the file)
4. `Self.dynamicSectionIds` static constant (search the file)

- [ ] **Step 2: Add the `selectedTab` state**

Just before `public init(context: ResourceDetailContext)` (around line 53), add:

```swift
    /// Selected tab in the segmented control. Always starts at `.overview`
    /// when the detail is freshly presented — no persistence across
    /// presentations (Pass 1 default; revisit in Pass 2 per founder feedback).
    @State private var selectedTab: ResourceDetailTab = .overview
```

- [ ] **Step 3: Add a private `tabSections` helper**

Below the existing `catalogSections(idIn:)` helper, add:

```swift
    /// All catalog sections (canonical + bespoke + stubs) that
    /// (a) gate-in for the current enabled capabilities and context,
    /// AND (b) belong to the supplied tab. Sorted by `priority` ascending.
    private func sectionsForTab(_ tab: ResourceDetailTab) -> [CapabilitySection] {
        CapabilitySectionCatalog.shared
            .sectionsFor(context: context)
            .filter { $0.tabId == tab.id }
    }
```

- [ ] **Step 4: Replace the body VStack contents with hero + segmented + tabContent**

The current body's inner VStack (lines ~59-81) reads exactly:

```swift
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                liveBanner
                if !context.attentionActions.isEmpty {
                    DetailAttentionView(context: context)
                }
                hero
                informationSection
                // All dynamic sections (canonical + bespoke + resource_links)
                // sourced from the CapabilitySectionCatalog and rendered in
                // priority order. Each section gates its own empty state —
                // CheckIn returns empty when no eventInteractor, Description
                // returns empty when no metadata text, etc. Per ontology
                // constitution Rule 6 (the view is a renderer; section
                // visibility lives in the section's own definition).
                catalogSections(idIn: Self.dynamicSectionIds)
                stubCapabilitySections
                SettingsSectionView(
                    onPresentEnableCapability: shouldShowEnableCapability
                        ? context.onPresentEnableCapability
                        : nil,
                    onArchive: nil
                )
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.lg)
```

Replace that **entire VStack** (including its modifiers) with:

```swift
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                liveBanner
                if !context.attentionActions.isEmpty {
                    DetailAttentionView(context: context)
                }
                hero
                informationSection

                RuulSegmentedControl(
                    selection: $selectedTab,
                    segments: ResourceDetailTab.allCases.map { ($0, $0.label) }
                )
                .padding(.top, RuulSpacing.xs)

                tabContent
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.lg)
```

This removes three blocks: `catalogSections(idIn: Self.dynamicSectionIds)`, `stubCapabilitySections`, and the `SettingsSectionView(...)` call. They are replaced by the segmented control + `tabContent` dispatcher (added next step).

- [ ] **Step 5: Add the `tabContent` ViewBuilder**

After the closing of `body` and before the next method, add this @ViewBuilder block:

```swift
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:    overviewContent
        case .activity:    activityContent
        case .rules:       rulesContent
        case .connections: connectionsContent
        case .governance:  governanceContent
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        let sections = sectionsForTab(.overview)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.overview.symbol,
                message: "No hay información para mostrar todavía."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        let sections = sectionsForTab(.activity)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.activity.symbol,
                message: "Aún no hay actividad. Cuando alguien interactúe con este recurso, lo verás aquí."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var rulesContent: some View {
        let sections = sectionsForTab(.rules)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.rules.symbol,
                message: "Sin reglas propias. Las reglas del grupo aplican aquí por defecto."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var connectionsContent: some View {
        let sections = sectionsForTab(.connections)
        if sections.isEmpty {
            emptyTab(
                symbol: ResourceDetailTab.connections.symbol,
                message: "Aún no hay recursos vinculados. Las conexiones aparecerán aquí cuando se agreguen."
            )
        } else {
            ForEach(sections, id: \.id) { section in
                section.render(context)
            }
        }
    }

    @ViewBuilder
    private var governanceContent: some View {
        GovernanceTabView(resource: context.resource, onArchive: nil)
    }

    @ViewBuilder
    private func emptyTab(symbol: String, message: String) -> some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: symbol)
                .ruulTextStyle(RuulTypography.title3)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(message)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    }
```

- [ ] **Step 6: Remove the now-dead `shouldShowEnableCapability` computed property**

The `SettingsSectionView` call from Step 4 used `shouldShowEnableCapability` (defined at `UniversalResourceDetailView.swift:382`). It is now unreferenced and Swift will emit a warning. Delete the entire computed property:

```swift
    private var shouldShowEnableCapability: Bool {
        // ...whatever body it has...
    }
```

Find it via:
```
grep -n "shouldShowEnableCapability" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
```

After deletion, both matches should be gone (the original declaration at ~line 382 and the original callsite at line 76 — the callsite was already removed in Step 4).

Note: the `catalogSections(idIn:)` helper method, the `stubCapabilitySections` computed property, and the `Self.dynamicSectionIds` static constant can stay defined for now (Swift won't error on unused private members). They become dead code; removed in a later cleanup pass to keep this diff focused on tab routing.

- [ ] **Step 7: Build to verify compilation**

Run:
```
cd ios && xcodebuild build -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -25
```

Expected: BUILD SUCCEEDED. If errors mention `SettingsSectionView`, you missed a reference in Step 6.

- [ ] **Step 8: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift
git commit -m "$(printf 'refactor(detail): replace single scroll with 5 universal tabs\n\nUniversalResourceDetailView renders hero + INFORMACIÓN as persistent\nidentity, then segmented control drives tab dispatch. Each tab filters\nthe catalog by tabId, with inline empty states.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 7: Drop `onPresentEnableCapability` from `ResourceDetailContext` + clean `ResourceDetailSheet`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailContext.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift`

- [ ] **Step 1: Remove the field from `ResourceDetailContext`**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailContext.swift`:

1. Delete the line `public let onPresentEnableCapability: () -> Void` (around line 44).
2. Delete the init param `onPresentEnableCapability: @escaping () -> Void = {},` (around line 76).
3. Delete the assignment `self.onPresentEnableCapability = onPresentEnableCapability` (around line 92).

- [ ] **Step 2: Remove the trigger + fullScreenCover from `ResourceDetailSheet`**

In `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift`:

1. Search for `@State private var enableCapabilityPresented` and delete that line.
2. Search for `.fullScreenCover(isPresented: $enableCapabilityPresented)` — delete the entire modifier block (the `.fullScreenCover` + its closing `}`, lines ~76-87).
3. Search for any callsite that passes `onPresentEnableCapability:` to a `ResourceDetailContext(...)` constructor in this file. Delete the argument.

- [ ] **Step 3: Build to verify compilation**

Run:
```
cd ios && xcodebuild build -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -25
```

Expected: BUILD SUCCEEDED. If errors mention `onPresentEnableCapability` or `enableCapabilityPresented`, you missed a reference — grep the whole `ios/` tree and delete remaining ones.

- [ ] **Step 4: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailContext.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/ResourceDetailSheet.swift
git commit -m "$(printf 'refactor(detail): drop onPresentEnableCapability + fullScreenCover\n\nGovernance tab now owns capability management. The context callback and\nthe sheet trigger become dead code.\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 8: Delete `SettingsSectionView.swift`

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift`

- [ ] **Step 1: Verify no remaining callers**

Run:
```
grep -rn "SettingsSectionView" ios/Packages ios/Tandas ios/TandasTests 2>/dev/null
```

Expected: only the file itself appears (the line declaring `public struct SettingsSectionView`). If any other matches, resolve them before deleting.

- [ ] **Step 2: Delete the file**

```
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift
```

- [ ] **Step 3: Build to verify compilation**

Run:
```
cd ios && xcodebuild build -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift
git commit -m "$(printf 'refactor(detail): remove SettingsSectionView (functionality in Governance tab)\n\nCo-Authored-By: claude-flow <ruv@ruv.net>')"
```

---

## Task 9: Full-suite tests + smoke

**Files:**
- No code changes — verification only.

- [ ] **Step 1: Run the full TandasTests suite**

Run:
```
cd ios && xcodebuild test -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -40
```

Expected: TEST SUCCEEDED. All capability + section + tab tests green. If any pre-existing test referenced `SettingsSectionView` or `onPresentEnableCapability`, fix or remove it inline and re-run (then commit the fix).

- [ ] **Step 2: Lefthook codegen check**

Run:
```
cd ios && lefthook run pre-commit 2>&1 | tail -20
```

Expected: All hooks pass with no codegen diff.

- [ ] **Step 3: Manual simulator smoke (founder runs this; agent prepares the launch)**

Boot the simulator:
```
cd ios && xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5
xcrun simctl boot 'iPhone 16 Pro' 2>/dev/null || true
open -a Simulator
```

Then in Xcode, ⌘R to run on iPhone 16 Pro.

Smoke checklist (verify with a human; agent reports completion when each ☑):
- ☐ Open any group → tap an upcoming event → 5 tabs visible: General / Actividad / Reglas / Conexiones / Gobierno
- ☐ Default tab is General. Hero + INFORMACIÓN visible above the segmented control
- ☐ Tap Actividad → existing activity feed renders (or empty state with the teaching copy)
- ☐ Tap Reglas → existing Rules section card renders (or empty state)
- ☐ Tap Conexiones → existing "RECURSOS" card renders (event-only) or empty state for non-events
- ☐ Tap Gobierno → ACTIVAS + DISPONIBLES capability lists render, Activar button works for an inactive capability
- ☐ RSVP / Check-in / Aportar still work from General tab unchanged
- ☐ Open a fund detail → 5 tabs still visible, Gobierno shows fund-relevant capabilities

- [ ] **Step 4: If smoke passes, no further commit needed**

The plan is complete. The branch contains 8 commits (1 per task + the spec commit).

If smoke reveals a regression: file a follow-up task, do NOT rush a fix on top of this branch unless the founder asks.

---

## Out of Scope (deferred to Pass 2+)

- Per-type tabs (Space → Reservations/Access/Schedule/Usage/Costs; Fund → Balance/Contributions/Expenses/Approvals; etc.)
- `LazyCapabilityActivator` for intent-driven activation
- `IntentCopyRegistry` for empty-state copy per (resource_type, tab)
- Connections empty-state CTA wired to `LinkResourcePickerSheet` for non-event types (today the picker is event-only via `link_resource_to_event` RPC)
- Per-resource scroll position persistence between tab switches
- Removing the now-unused `catalogSections(idIn:)` helper + `dynamicSectionIds` constant from `UniversalResourceDetailView`
- Per-resource activity filter (`SystemEventRepository.query(referenceId:)` repo extension)
