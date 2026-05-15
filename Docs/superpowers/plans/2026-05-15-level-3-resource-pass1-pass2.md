# Level 3 Resource Polish — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the last 3 visible polymorphism gaps in Nivel 3 — (a) add minimal detail views for Fund/Space/Right, (b) consolidate the hybrid HomeView into a single polymorphic feed, (c) move the last `switch resourceType` from a View into `ResourceTypeChrome`.

**Architecture:** Two sequential passes. Pass 1 adds 3 detail views and a single routing switch inside `UniversalResourceDetailView`. Pass 2 makes `HomeView` and `HomeCoordinator` consume the polymorphic `ResourceRepository` instead of `EventRepository`, and migrates the cover-height switch to `ResourceTypeChrome`.

**Tech Stack:** SwiftUI iOS 26+, Swift 6 strict concurrency, `@Observable` view models, supabase-swift 2.20+.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-3-resource-polish.md`.

---

## File Structure

### Pass 1 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/FundDetailView.swift` | **Create** | ~150 L. Reads `metadata.name`, `metadata.currency`, optional `metadata.goal_amount`. Shows capability list + archive footer (no-op for now) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/SpaceDetailView.swift` | **Create** | ~140 L. Reads `metadata.location_name`, `metadata.capacity`. Shows enabled capabilities |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/RightDetailView.swift` | **Create** | ~120 L. Minimal scaffold — name + status + enabled capabilities |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift` | **Modify** | Add a single `switch resourceType` at the entry of `body` routing to the type-specific view. Keep the existing event rendering as the default branch |

### Pass 2 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift` | **Modify** | Add `coverHeroHeight: CGFloat` to the struct + return value per case |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift` | **Modify** | Replace `coverHeightFor(_:)` switch (line 131) with `ResourceTypeChrome.resolve(_:).coverHeroHeight` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift` | **Modify** | Add `upcomingResources: [ResourceRow]` populated via `resourceRepo.list(types: [.fund, .asset, .slot, .space])`. Keep `upcomingEvents: [Event]` for now |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift` | **Modify** | Merge "Próximos eventos" + "Otros recursos" sections into one "Próximas actividades" section. Render each item via `ResourceTypeChrome` |

### Verified facts (use exact names; do NOT re-verify in subagents)

- `ResourceRow` at `ios/Packages/RuulCore/Sources/RuulCore/Resources/ResourceRow.swift:13` with fields: `id`, `groupId`, `resourceType: ResourceType`, `status: String`, `metadata: JSONConfig`, `createdBy: UUID?`, `createdAt: Date`, `updatedAt: Date`, `archivedAt: Date?`.
- `JSONConfig.subscript(_: String) -> JSONValue?` — `metadata["currency"]` returns `JSONValue?`. Cases: `.string(String)`, `.int(Int)`, `.bool(Bool)`, `.double(Double)`, etc. — confirm in `ios/Packages/RuulCore/Sources/RuulCore/JSONConfig.swift` if unclear.
- `ResourceType: String, Codable, CaseIterable` with cases `.event`, `.fund`, `.asset`, `.slot`, `.space`, `.right`, `.unknown` (per the existing switch at line 131 of UniversalResourceDetailView).
- `ResourceTypeChrome.resolve(_: ResourceType) -> ResourceTypeChrome` exists at `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift`. Today exposes `symbol`, `semanticColor`, `labelKey`.
- `RuulSize.coverHero` and `RuulSize.heroLarge` are the two current sizes (per the switch comment).
- `LiveResourceRepository.list(in: UUID, types: [ResourceType], statuses: [String]?, limit: Int) async throws -> [ResourceRow]` — confirm by reading `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ResourceRepository.swift` before Task 6.
- `Event: Resource` conforms (per HomeCoordinator line 14 comment).
- Tokens: `RuulRadius.lg`/`.md`, `RuulTypography.mono`/`.title`/`.body`/`.caption`/`.captionBold`.
- Use `RuulCore.Group` not bare `Group`.

---

## Pass 1 — 3 detail views + routing (Tasks 1-4)

### Task 1: Create `FundDetailView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/FundDetailView.swift`

**Why:** Fund is currently created via wizard but tap-detail goes to an empty UniversalResourceDetailView fallback. Most strategically valuable missing detail.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Detail view for a fund — pooled money resource.
/// Metadata expected: `name: String` (required), `currency: String` (required),
/// `goal_amount: Double` (optional). Shows enabled capabilities and an archive
/// footer placeholder (Pass 3 wires the actual RPC).
public struct FundDetailView: View {
    public let fund: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(fund: ResourceRow) { self.fund = fund }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                hero
                informationSection
                capabilitiesPlaceholder
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }

    // MARK: - Computed

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.fund) }

    private var name: String {
        if case .string(let s)? = fund.metadata["name"], !s.isEmpty { return s }
        return "Fondo"
    }

    private var currency: String {
        if case .string(let s)? = fund.metadata["currency"] { return s }
        return "MXN"
    }

    private var goalAmount: Double? {
        if case .double(let d)? = fund.metadata["goal_amount"] { return d }
        if case .int(let i)? = fund.metadata["goal_amount"] { return Double(i) }
        return nil
    }

    // MARK: - Sections

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .font(.system(size: 32))
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 60, height: 60)
                .background(chrome.semanticColor.opacity(0.12), in: RoundedRectangle(cornerRadius: RuulRadius.md))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("\(currency) · creado \(relativeCreated)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Moneda", value: currency)
            divider
            row(label: "Estado", value: fund.status.capitalized)
            if let goal = goalAmount {
                divider
                row(label: "Meta", value: formatCurrency(goal))
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Saldo + contribuciones")
                .opacity(0.55)
        }
    }

    private var relativeCreated: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return f.localizedString(for: fund.createdAt, relativeTo: .now)
    }

    private func formatCurrency(_ amount: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "\(currency) \(Int(amount))"
    }

    // MARK: - Reusable

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(RuulSpacing.md)
    }
}
```

NOTE: confirm `RuulTypography.sectionLabel` exists with `grep -n "sectionLabel" ios/Packages/RuulUI/Sources/RuulUI/Tokens/Typography.swift`. Fall back to `RuulTypography.caption.weight(.medium)` if absent.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/FundDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(resource): FundDetailView — minimal fund scaffold

Renders type chrome + name + currency + creation date + status. Goal
amount when metadata.goal_amount is present. Capabilities section is
a placeholder until ledger projection wires in a future pass. Routing
from UniversalResourceDetailView lands in Task 4.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: Create `SpaceDetailView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/SpaceDetailView.swift`

**Why:** Space ("cancha, salón, casa, oficina") is creable in the wizard. Needs detail.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import RuulUI
import RuulCore

public struct SpaceDetailView: View {
    public let space: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(space: ResourceRow) { self.space = space }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                hero
                informationSection
                capabilitiesPlaceholder
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.space) }

    private var name: String {
        if case .string(let s)? = space.metadata["name"], !s.isEmpty { return s }
        if case .string(let s)? = space.metadata["location_name"], !s.isEmpty { return s }
        return "Espacio"
    }

    private var address: String? {
        if case .string(let s)? = space.metadata["address"], !s.isEmpty { return s }
        return nil
    }

    private var capacity: Int? {
        if case .int(let i)? = space.metadata["capacity"] { return i }
        return nil
    }

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .font(.system(size: 32))
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 60, height: 60)
                .background(chrome.semanticColor.opacity(0.12), in: RoundedRectangle(cornerRadius: RuulRadius.md))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let cap = capacity {
                    Text("Capacidad: \(cap)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Estado", value: space.status.capitalized)
            if let address {
                divider
                row(label: "Dirección", value: address)
            }
            if let cap = capacity {
                divider
                row(label: "Capacidad", value: "\(cap)")
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Reservas + disponibilidad")
                .opacity(0.55)
        }
    }

    // Reusable container/row helpers — identical to FundDetailView

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/SpaceDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(resource): SpaceDetailView — minimal space scaffold

Renders type chrome + name + capacity + address from metadata. Used by
UniversalResourceDetailView's routing in Task 4. Booking/availability
capabilities placeholder until Phase 2.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: Create `RightDetailView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/RightDetailView.swift`

**Why:** Right (membresía externa, equity, voto, acceso) is the most abstract resource type. Scaffold keeps the polymorphism complete.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import RuulUI
import RuulCore

public struct RightDetailView: View {
    public let right: ResourceRow
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(right: ResourceRow) { self.right = right }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                hero
                informationSection
                capabilitiesPlaceholder
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
    }

    private var chrome: ResourceTypeChrome { ResourceTypeChrome.resolve(.right) }

    private var name: String {
        if case .string(let s)? = right.metadata["name"], !s.isEmpty { return s }
        if case .string(let s)? = right.metadata["title"], !s.isEmpty { return s }
        return "Derecho"
    }

    private var kind: String? {
        if case .string(let s)? = right.metadata["right_kind"], !s.isEmpty { return s }
        return nil
    }

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .font(.system(size: 32))
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 60, height: 60)
                .background(chrome.semanticColor.opacity(0.12), in: RoundedRectangle(cornerRadius: RuulRadius.md))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let kind {
                    Text(kind)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var informationSection: some View {
        sectionContainer(title: "INFORMACIÓN") {
            row(label: "Estado", value: right.status.capitalized)
            if let kind {
                divider
                row(label: "Tipo", value: kind)
            }
        }
    }

    private var capabilitiesPlaceholder: some View {
        sectionContainer(title: "CAPABILITIES") {
            row(label: "Próximamente", value: "Acceso + transferencia")
                .opacity(0.55)
        }
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(RuulSpacing.md)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Views/RightDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(resource): RightDetailView — minimal right scaffold

Minimal scaffold for the right resource type (membresía externa, equity,
voto, acceso). Renders type chrome + name + right_kind. Polymorphism
completeness — every frozen type now has a detail view.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: Wire routing in `UniversalResourceDetailView`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

**Why:** A single dispatch switch routes Fund/Space/Right to their dedicated views; Event (and everything else) keeps the rich existing rendering.

- [ ] **Step 1: Add the dispatch at the top of `body`**

Open `UniversalResourceDetailView.swift`. Find `public var body: some View {` (around line 40-60 — confirm with grep). At the very top of `body`, before the existing scroll/zstack/etc., insert a dispatch:

```swift
public var body: some View {
    SwiftUI.Group {
        switch context.resource.resourceType {
        case .fund:
            FundDetailView(fund: typedResourceRow)
        case .space:
            SpaceDetailView(space: typedResourceRow)
        case .right:
            RightDetailView(right: typedResourceRow)
        default:
            existingBody  // <- the rest of the existing body content
        }
    }
}
```

You may need to extract the existing body into a private computed property `existingBody: some View` (or just rename the existing implementation to `eventBody` and call it from `.default`). Read the current implementation first to pick the cleanest refactor.

The `typedResourceRow` helper bridges from the view's `context: ResourceDetailContext` to a `ResourceRow`:

```swift
private var typedResourceRow: ResourceRow {
    // The existing detail view receives context.resource which is the
    // canonical ResourceRow (or an Event that conforms to Resource).
    // If context.resource is already ResourceRow, return it; if it's
    // Event, build a ResourceRow from its fields.
    if let row = context.resource as? ResourceRow { return row }
    // Fall-through synthesis — only events should hit this in V1.
    return ResourceRow(
        id: context.resource.id,
        groupId: context.resource.groupId,
        resourceType: context.resource.resourceType,
        status: "open",
        metadata: context.resource.metadata,
        createdAt: .now,
        updatedAt: .now
    )
}
```

NOTE: confirm `context.resource` type signature. If it's `any Resource` then the `as? ResourceRow` cast works at runtime. If `context.resource` is statically `Event`, the cast always fails — in that case, just synthesize ResourceRow from the existing properties.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(resource): UniversalResourceDetailView dispatches Fund/Space/Right

Adds a single switch at the top of body to route the three new minimal
detail views. Event and any other types fall through to the existing
rich rendering. Justified single-point-of-discrimination — Views below
remain polymorphic via CapabilityResolver + ResourceTypeChrome.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 3: Tag Pass 1 milestone**

```bash
git tag -a level3-pass1-complete -m "Level 3 redesign — Pass 1 (Fund/Space/Right detail views) complete"
```

---

## Pass 2 — coverHeroHeight + polymorphic HomeView (Tasks 5-7)

### Task 5: Add `coverHeroHeight` to `ResourceTypeChrome` + remove the switch

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`

**Why:** Last `switch resource.resourceType` inside a View. Migrating to Chrome closes the loop.

- [ ] **Step 1: Extend `ResourceTypeChrome` struct**

Open `ResourceTypeChrome.swift`. Add to the struct:

```swift
public let coverHeroHeight: CGFloat
```

Update each `case` in `resolve(_:)` to include the new field. Event keeps the rich cover; others get the compact one:

```swift
case .event:
    return ResourceTypeChrome(
        symbol: "calendar",
        semanticColor: .accentColor,
        labelKey: "resource.type.event",
        coverHeroHeight: 400  // matches RuulSize.coverHero
    )
case .fund:
    return ResourceTypeChrome(
        symbol: "banknote",
        semanticColor: .green,
        labelKey: "resource.type.fund",
        coverHeroHeight: 240
    )
// ... and so on for asset / slot / space / right / unknown — all use 240 except event
```

The exact numeric values should match the existing `RuulSize.coverHero` (events) and `RuulSize.heroLarge` (others). Confirm with `grep -n "coverHero\|heroLarge" ios/Packages/RuulUI/Sources/RuulUI/Tokens/Size.swift` (or wherever `RuulSize` is defined). Use the matched values.

- [ ] **Step 2: Remove the switch in `UniversalResourceDetailView`**

Open `UniversalResourceDetailView.swift`. Find:

```swift
private func coverHeightFor(_ type: ResourceType) -> CGFloat {
    switch type {
    case .event:                          return RuulSize.coverHero
    case .fund, .asset, .slot, .space,
         .right, .unknown:                return RuulSize.heroLarge
    }
}
```

Replace the function body with:

```swift
private func coverHeightFor(_ type: ResourceType) -> CGFloat {
    ResourceTypeChrome.resolve(type).coverHeroHeight
}
```

(Or, if the function is only called once, inline the call directly at the call site and delete the function.)

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceTypeChrome.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift && \
git commit -m "$(cat <<'EOF'
refactor(resource): coverHeroHeight moves to ResourceTypeChrome

Last switch resource.resourceType inside a View is gone — coverHeight
lookup now lives in the chrome struct alongside symbol/color/labelKey.
View remains polymorphic; height is type metadata.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 6: `HomeCoordinator` exposes `upcomingResources: [ResourceRow]`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift`

**Why:** HomeView currently has two parallel feeds (events + nonEventResources). Step 1 of consolidation is exposing a single sorted list from the coordinator.

- [ ] **Step 1: Verify `ResourceRepository` is in HomeCoordinator's deps**

```bash
grep -n "resourceRepo\|ResourceRepository" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift
```

If `resourceRepo` is already a property, skip injection. If not, add it to the `init` and a stored property `private let resourceRepo: any ResourceRepository`. Update every caller of `HomeCoordinator(...)` (probably 1 in `RootShell.swift`).

- [ ] **Step 2: Add `upcomingResources: [ResourceRow]` state**

In the `HomeCoordinator` class, add:

```swift
public private(set) var upcomingResources: [ResourceRow] = []
```

In `refresh(force:)`, after the existing `eventRepo` call, add:

```swift
async let resourcesTask: [ResourceRow] = (try? await resourceRepo.list(
    in: group.id,
    types: [.fund, .asset, .slot, .space],
    statuses: nil,
    limit: 20
)) ?? []
self.upcomingResources = await resourcesTask
```

(Adjust the `resourceRepo.list` call to match its actual signature — argument labels may differ. Look at the call from `AssetDetailView.swift` for the canonical pattern.)

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift && \
git commit -m "$(cat <<'EOF'
feat(home): HomeCoordinator loads upcomingResources polymorphically

Adds `upcomingResources: [ResourceRow]` populated via ResourceRepository
for non-event types (fund/asset/slot/space). Events still come from
eventRepo for now to preserve existing UI bindings. HomeView merges
both into a single feed in Task 7.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 7: HomeView merges into one polymorphic feed

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift`

**Why:** Final consolidation. Two sections → one "Próximas actividades" section ordered chronologically.

- [ ] **Step 1: Locate the two current sections**

```bash
grep -n "Próximos eventos\|Otros recursos\|upcomingEvents\|nonEventResources\|upcomingResources" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift | head -20
```

This will show you the exact lines where the two sections render.

- [ ] **Step 2: Replace the two sections with one merged feed**

Strategy: build a small struct to represent a heterogeneous row:

```swift
private struct ActivityFeedItem: Identifiable {
    let id: UUID
    let kind: Kind
    let resource: any Resource
    let sortDate: Date

    enum Kind { case event(Event), other(ResourceRow) }
}

private var mergedFeed: [ActivityFeedItem] {
    let eventItems = coordinator.upcomingEvents.map {
        ActivityFeedItem(
            id: $0.id,
            kind: .event($0),
            resource: $0,
            sortDate: $0.startsAt ?? .distantFuture
        )
    }
    let otherItems = coordinator.upcomingResources.map {
        ActivityFeedItem(
            id: $0.id,
            kind: .other($0),
            resource: $0,
            sortDate: $0.createdAt
        )
    }
    return (eventItems + otherItems).sorted { $0.sortDate < $1.sortDate }
}
```

Confirm `Event.startsAt: Date?` exists; if it's nested elsewhere, adapt. If Event doesn't have a Date directly accessible, fall back to `$0.createdAt`.

Replace the two existing ForEach blocks with one:

```swift
Text("Próximas actividades")
    .ruulTextStyle(RuulTypography.sectionLabel)
    .foregroundStyle(Color.ruulTextTertiary)
    .padding(.horizontal, RuulSpacing.lg)

LazyVStack(spacing: RuulSpacing.sm) {
    ForEach(mergedFeed) { item in
        feedRow(item)
    }
}
.padding(.horizontal, RuulSpacing.lg)
```

Where `feedRow(_:)` is a new helper:

```swift
@ViewBuilder
private func feedRow(_ item: ActivityFeedItem) -> some View {
    switch item.kind {
    case .event(let event):
        // Keep existing event card rendering — find it via the
        // current "upcomingEvents" ForEach body and lift it here.
        existingEventCard(event)
    case .other(let row):
        polymorphicResourceCard(row)
    }
}

@ViewBuilder
private func polymorphicResourceCard(_ row: ResourceRow) -> some View {
    let chrome = ResourceTypeChrome.resolve(row.resourceType)
    Button {
        // Route to detail (find existing pattern — likely opens
        // UniversalResourceDetailView via router or NavigationLink).
        onOpenResource?(row)
    } label: {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: chrome.symbol)
                .ruulTextStyle(RuulTypography.subheadMedium)
                .foregroundStyle(chrome.semanticColor)
                .frame(width: 32, height: 32)
                .background(chrome.semanticColor.opacity(0.12), in: RoundedRectangle(cornerRadius: RuulRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(row))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(row.status.capitalized)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5))
    }
    .buttonStyle(.plain)
}

private func rowTitle(_ row: ResourceRow) -> String {
    if case .string(let s)? = row.metadata["name"], !s.isEmpty { return s }
    if case .string(let s)? = row.metadata["title"], !s.isEmpty { return s }
    return row.resourceType.rawValue.capitalized
}
```

If `onOpenResource` doesn't exist on `HomeView`, add it as an init param `public var onOpenResource: ((ResourceRow) -> Void)?` and wire from `HomeTab` to navigate (likely a `router.openResource(...)` or push to `UniversalResourceDetailView`). If wiring is complex, leave the tap as a no-op for this task and create a follow-up to wire navigation.

- [ ] **Step 3: Build + smoke + commit + tag**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```

Expected BUILD SUCCEEDED.

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift && \
git commit -m "$(cat <<'EOF'
feat(home): polymorphic single-feed merging events + other resources

The two parallel sections ("Próximos eventos" + "Otros recursos") merge
into one chronologically-sorted "Próximas actividades" feed. Each row
renders via ResourceTypeChrome — heterogeneous types coexist in one
list, no more grouping by vertical.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)" && \
git tag -a level3-pass2-complete -m "Level 3 redesign — Pass 2 (polymorphic HomeView + cover chrome) complete"
```

---

## Done When

- All 7 tasks committed.
- Tap-detail on a Fund / Space / Right resource opens its dedicated view (not empty fallback).
- `UniversalResourceDetailView` has zero `switch resource.resourceType` in view layer (the routing switch at the top counts as structural dispatch, not decorative discrimination).
- `ResourceTypeChrome` carries `coverHeroHeight`.
- HomeView shows one merged "Próximas actividades" feed.
- Build clean.
- Two tags: `level3-pass1-complete`, `level3-pass2-complete`.

---

## Out of Scope

- Pass 3 (archive/restore resources UI — RPCs already exist)
- Pass 4 (migrate 15 remaining `EventRepository` call sites)
- Wiring Fund-specific actions (contribute, approve expense)
- Wiring Slot booking from Space detail
- Cross-group polymorphic feed (`Mi línea de tiempo` from L0 Pass 4 spec)
