# Level 5 Capability Management — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every resource capability fully manageable from the Resource Detail surface — enable, disable with dependency warnings, and edit per-capability configuration jsonb post-creation.

**Architecture:** Two sequential passes. Pass 1 rebrands `EnableCapabilitySheet` → `ManageCapabilitiesSheet` (shows both enabled + inactive) + creates a generic `EditCapabilityConfigSheet` that reuses `BuilderFieldRenderer`. Pass 2 adds `CapabilityDependencyResolver` for dependency cascade UX.

**Tech Stack:** SwiftUI iOS 26+, Swift 6 strict concurrency.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-5-capability-management.md`.

---

## File Structure

### Pass 1 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EnableCapabilitySheet.swift` | **Rename → `ManageCapabilitiesSheet.swift`** + significant rewrite | List BOTH enabled (with disable + edit-config actions) AND inactive (with enable action). ~280 L |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EditCapabilityConfigSheet.swift` | **Create** (~200 L) | Generic editor: takes `CapabilityBlock` + current config `JSONConfig` → renders `BuilderFieldRenderer` over `requiredFields + optionalFields` → calls `updateConfig` on save |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift` | **Modify** | Button label: "Activar / desactivar capabilities" → "Manejar capabilities". The callback flow goes through the renamed sheet |
| Any caller of `EnableCapabilitySheet(...)` | **Modify** | Audit and update — type name + callback shape |

### Pass 2 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityDependencyResolver.swift` | **Create** (~80 L) | Pure logic over `CapabilityCatalog.v1`. Functions: `dependentsOf(_: String, in: Set<String>) -> [String]` and `dependenciesOf(_: String) -> [String]` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift` | **Modify** | At disable-tap: query `dependentsOf` — if non-empty, present blocking alert with cascade option. At enable-tap: query `dependenciesOf` — if any disabled, present "Activar también" CTA |

### Verified facts (use directly)

- `ResourceCapabilityRepository` protocol exists at `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ResourceCapabilityRepository.swift` with: `list(resourceId:)`, `enable(_:on:config:)`, `disable(_:on:)`, `updateConfig(blockId:on:config:)`. **All four are implemented** in Live + Mock — no BE work needed.
- `CapabilityBlock` is a protocol at `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityBlock.swift:18`. Has `id: String`, `displayName: String`, `summary: String`, `status: CapabilityBlockStatus`, `enabledResourceTypes: [ResourceType]`, `requiredFields: [BuilderField]`, `optionalFields: [BuilderField]`, `dependencies: [String]`.
- `CapabilityCatalog.v1.byId: [String: CapabilityBlock]` — lookup.
- `CapabilityCatalog.v1.blocks(for: ResourceType) -> [CapabilityBlock]`.
- `BuilderField` (line 119 of CapabilityBlock.swift) drives the renderer.
- `BuilderFieldRenderer` at `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/BuilderFieldRenderer.swift` (373 L) renders any field type — reuse it.
- `JSONConfig` is the canonical config payload (codable + dynamic access).
- `app.resourceCapabilityRepo: any ResourceCapabilityRepository` — confirm with `grep -n "resourceCapabilityRepo\|resourceCapRepo\|capabilityRepo" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`.
- Modal policy: `.fullScreenCover` not `.sheet`.
- Token names: `RuulRadius.lg`/`.md`, `RuulTypography.title/.body/.caption/.captionBold/.sectionLabel`, standard Color tokens.

---

## Pass 1 — Manage sheet + config editor (Tasks 1-4)

### Task 1: Rename + rewrite `EnableCapabilitySheet` → `ManageCapabilitiesSheet`

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EnableCapabilitySheet.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift`

**Why:** Today the sheet only lists inactive blocks. Users have no way to disable a capability once on. Restructuring into two sections (Activas / Disponibles) with per-row actions makes the full lifecycle reachable.

- [ ] **Step 1: Delete the old file**

```bash
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EnableCapabilitySheet.swift
```

- [ ] **Step 2: Create the new file**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Manage every capability on a resource — enable inactive ones, edit
/// configs of enabled ones, or disable enabled ones.
///
/// Replaces the old `EnableCapabilitySheet`, which only listed inactive
/// blocks. Two sections: "Activas" (with per-row context menu for
/// Editar config / Desactivar) and "Disponibles" (with Activar button).
public struct ManageCapabilitiesSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resourceId: UUID
    public let resourceType: ResourceType
    /// Capabilities currently enabled on this resource, with their
    /// configs. The parent owns the truth — this sheet writes mutations
    /// and signals back via `onChanged`.
    public let enabled: [ResourceCapability]
    /// Closure called whenever a mutation succeeds so the parent can
    /// refresh its capability list.
    public let onChanged: () -> Void

    @State private var pendingId: String?
    @State private var errorText: String?
    @State private var editingBlock: (block: CapabilityBlock, config: JSONConfig)?

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

    private var availableBlocks: [CapabilityBlock] {
        CapabilityCatalog.v1.blocks(for: resourceType)
            .filter { !enabledIds.contains($0.id) }
    }

    private var enabledBlocks: [(block: CapabilityBlock, row: ResourceCapability)] {
        enabled.compactMap { row in
            guard let block = CapabilityCatalog.v1.byId[row.capabilityBlockId] else { return nil }
            return (block, row)
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
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
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Capabilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
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
        }
    }

    // MARK: - Rows

    private func enabledRow(block: CapabilityBlock, row: ResourceCapability) -> some View {
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
                    Task { await disable(block.id) }
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

    private func availableRow(_ block: CapabilityBlock) -> some View {
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
                Task { await enable(block.id) }
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

    // MARK: - Helpers

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
private struct EditingContext: Identifiable, Hashable {
    let block: CapabilityBlock
    let config: JSONConfig

    var id: String { block.id }

    static func == (lhs: EditingContext, rhs: EditingContext) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

NOTES on adaptations:
- `ResourceCapability` model — confirm fields with `grep -n "public struct ResourceCapability\|capabilityBlockId\|enabled\b\|config" ios/Packages/RuulCore/Sources/RuulCore/Capabilities/ResourceCapability.swift`. If `capabilityBlockId` is named differently (`capability` / `blockId`), adapt the accessors.
- `app.resourceCapabilityRepo` exact property — verify with `grep -n "resourceCapabilityRepo\|resourceCapRepo" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`. Adjust the call.
- `CapabilityCatalog.v1.byId` and `.blocks(for:)` — confirm signatures.
- `JSONConfig.empty` static constant — confirm with `grep -n "public static let empty\|public static var empty" ios/Packages/RuulCore/Sources/RuulCore/JSONConfig.swift`. If absent, use `JSONConfig()` or `JSONConfig(empty:)` whatever the canonical empty literal is.

- [ ] **Step 3: Build — expect failures in callers**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Errors should be in callers of `EnableCapabilitySheet(...)` — Tasks 3+4 fix them.

- [ ] **Step 4: Commit (broken-build OK)**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EnableCapabilitySheet.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift && \
git commit -m "$(cat <<'EOF'
refactor(capability): rename EnableCapabilitySheet → ManageCapabilitiesSheet

Two sections (Activas with Editar/Desactivar context menu + Disponibles
with Activar button). Build is broken until SettingsSectionView callers
update — fixed in Tasks 3+4. EditCapabilityConfigSheet lands in Task 2.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: Create `EditCapabilityConfigSheet`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EditCapabilityConfigSheet.swift`

**Why:** Today configs (rsvp deadline, voting quorum, rotation order) are inmutable post-creation. This sheet reuses `BuilderFieldRenderer` over `block.requiredFields + optionalFields` for a generic editor.

- [ ] **Step 1: Inspect `BuilderFieldRenderer` to confirm API**

```bash
sed -n '1,40p' ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/BuilderFieldRenderer.swift
```

Confirm the public API — what state does it own, how does it read/write JSONConfig?

- [ ] **Step 2: Create the editor**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EditCapabilityConfigSheet.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Generic per-capability config editor. Reuses `BuilderFieldRenderer`
/// — the same component the wizard uses in step 3 — so capability
/// authors don't need a new view per capability.
public struct EditCapabilityConfigSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resourceId: UUID
    public let block: CapabilityBlock
    public let initialConfig: JSONConfig
    public let onSaved: () -> Void

    @State private var config: JSONConfig
    @State private var saving = false
    @State private var errorText: String?

    public init(
        resourceId: UUID,
        block: CapabilityBlock,
        initialConfig: JSONConfig,
        onSaved: @escaping () -> Void
    ) {
        self.resourceId = resourceId
        self.block = block
        self.initialConfig = initialConfig
        self.onSaved = onSaved
        self._config = State(initialValue: initialConfig)
    }

    private var fields: [BuilderField] {
        block.requiredFields + block.optionalFields
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    Text(block.summary)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if fields.isEmpty {
                        Text("Esta capability no tiene opciones.")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextTertiary)
                    } else {
                        VStack(spacing: RuulSpacing.md) {
                            ForEach(fields, id: \.id) { field in
                                BuilderFieldRenderer(
                                    field: field,
                                    value: binding(for: field)
                                )
                            }
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle(block.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Guardando…" : "Guardar") {
                        Task { await save() }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private func binding(for field: BuilderField) -> Binding<JSONValue?> {
        Binding(
            get: { config[field.id] },
            set: { newValue in
                if let v = newValue {
                    config[field.id] = v
                } else {
                    config.remove(field.id)
                }
            }
        )
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            _ = try await app.resourceCapabilityRepo.updateConfig(
                blockId: block.id,
                on: resourceId,
                config: config
            )
            onSaved()
            dismiss()
        } catch {
            errorText = "No pudimos guardar la configuración."
        }
    }
}
```

NOTES:
- `BuilderFieldRenderer` init signature — **confirm before writing**. The above assumes `BuilderFieldRenderer(field:value:)` where `value: Binding<JSONValue?>`. Read the renderer file and adapt the init labels + binding type. If the renderer takes a different binding shape (e.g., `Binding<JSONConfig>` directly), pass `$config` and let the renderer handle field lookup internally.
- `JSONConfig.subscript(_: String) -> JSONValue?` — confirm and adapt accessor pattern.
- `JSONConfig.remove(_:)` — if absent, just set `config[field.id] = nil` (subscript with nil should clear).

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/EditCapabilityConfigSheet.swift && \
git commit -m "$(cat <<'EOF'
feat(capability): EditCapabilityConfigSheet — generic config editor

Reuses BuilderFieldRenderer over block.requiredFields + optionalFields.
Calls ResourceCapabilityRepository.updateConfig on save. Zero new code
per capability — the field catalog drives everything.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: Update `SettingsSectionView` label and ensure callback shape matches

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift`

**Why:** The button that opens the sheet currently says "Activar / desactivar capabilities" but only enable was wired. Update label + verify callback signature still matches.

- [ ] **Step 1: Audit current callsite**

```bash
grep -n "SettingsSectionView\|onPresentEnableCapability\|EnableCapabilitySheet" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift
```

- [ ] **Step 2: Rename callback if needed and update label**

If `onPresentEnableCapability` is the existing param, it can stay (functional rename optional). Update the button text in the view body:

```swift
// Was:
Text("Activar / desactivar capabilities")
// Now:
Text("Manejar capabilities")
```

Subtitle/explanation copy can be updated too (e.g., "Activa, configura o desactiva las capacidades de este recurso.").

- [ ] **Step 3: Build (may still fail until Task 4)**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Sections/SettingsSectionView.swift && \
git commit -m "$(cat <<'EOF'
ui(capability): SettingsSection label → "Manejar capabilities"

Reflects the new ManageCapabilitiesSheet behavior (full lifecycle —
enable, edit config, disable). Callback signature unchanged.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: Update presenter / callsites of the old sheet

**Files:**
- Modify: every caller of `EnableCapabilitySheet(...)` — find with grep

**Why:** Old caller signature was `EnableCapabilitySheet(resourceId:resourceType:alreadyEnabled:onEnabled:)`. New is `ManageCapabilitiesSheet(resourceId:resourceType:enabled:onChanged:)`. Different types — must update.

- [ ] **Step 1: Find all callsites**

```bash
grep -rn "EnableCapabilitySheet\|ManageCapabilitiesSheet" ios/Packages ios/Tandas --include='*.swift' | grep -v "\.build"
```

The most likely location is `UniversalResourceDetailView.swift` or `EventDetailCoordinator.swift` — wherever `onPresentEnableCapability` is wired.

- [ ] **Step 2: Update each callsite**

The old call:

```swift
EnableCapabilitySheet(
    resourceId: ...,
    resourceType: ...,
    alreadyEnabled: enabledIds,
    onEnabled: { ... }
)
```

Replace with:

```swift
ManageCapabilitiesSheet(
    resourceId: ...,
    resourceType: ...,
    enabled: enabledRows,  // [ResourceCapability], not [String]
    onChanged: { ... }
)
```

The caller must produce `[ResourceCapability]` instead of `Set<String>`. If the caller currently has only the set of ids, it needs to load the full rows via `resourceCapabilityRepo.list(resourceId:)`. Easiest: pass through `context.resourceCapabilities` (or whatever name the caller has for the typed list — confirm with `grep -n "resourceCapabilities\|capabilities: \[" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift`).

- [ ] **Step 3: Build clean**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```

Expected BUILD SUCCEEDED. If errors remain, they describe what's missing — fix and rerun.

- [ ] **Step 4: Commit + tag Pass 1**

```bash
git add $(grep -rln "ManageCapabilitiesSheet" ios/Packages ios/Tandas --include='*.swift' | grep -v "\.build" | head -20) && \
git commit -m "$(cat <<'EOF'
feat(capability): wire ManageCapabilitiesSheet from Resource Detail

Callsites updated from EnableCapabilitySheet → ManageCapabilitiesSheet,
including the [ResourceCapability] payload change. Pass 1 complete.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)" && \
git tag -a level5-pass1-complete -m "Level 5 redesign — Pass 1 (manage + config edit) complete"
```

---

## Pass 2 — Dependency cascade (Tasks 5-7)

### Task 5: Create `CapabilityDependencyResolver`

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityDependencyResolver.swift`

**Why:** Pure logic that answers: "if I disable RSVP, what else breaks?" and "if I enable check_in, what does it need first?".

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Pure-logic helper over `CapabilityCatalog.v1` that answers
/// dependency questions for the management UI.
public struct CapabilityDependencyResolver: Sendable {
    public init() {}

    /// Returns block ids currently enabled on the resource that declare
    /// `targetId` as one of their dependencies. Disabling `targetId`
    /// would break them.
    public func dependents(
        of targetId: String,
        in enabledIds: Set<String>
    ) -> [String] {
        enabledIds.compactMap { id -> String? in
            guard id != targetId else { return nil }
            guard let block = CapabilityCatalog.v1.byId[id] else { return nil }
            return block.dependencies.contains(targetId) ? id : nil
        }
        .sorted()
    }

    /// Returns block ids that `targetId` declares as dependencies but
    /// are not currently enabled. Enabling `targetId` requires these.
    public func missingDependencies(
        of targetId: String,
        in enabledIds: Set<String>
    ) -> [String] {
        guard let block = CapabilityCatalog.v1.byId[targetId] else { return [] }
        return block.dependencies
            .filter { !enabledIds.contains($0) }
            .sorted()
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
git add ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityDependencyResolver.swift && \
git commit -m "$(cat <<'EOF'
feat(capability): CapabilityDependencyResolver — pure dependency logic

Two queries: dependents(of:in:) for "what breaks if I disable X" and
missingDependencies(of:in:) for "what does X need first". Used by
ManageCapabilitiesSheet to drive cascade UX in Tasks 6-7.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 6: Wire dependency warning on disable

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift`

**Why:** Disabling RSVP silently while check_in is on leaves check_in in an invalid state. Show an alert that lists the dependents.

- [ ] **Step 1: Add state for the cascade alert**

In `ManageCapabilitiesSheet`, add:

```swift
@State private var cascadeAlert: CascadeAlertContext?

private struct CascadeAlertContext: Identifiable {
    let id = UUID()
    let targetId: String
    let dependents: [String]
}
```

- [ ] **Step 2: Intercept the disable tap**

Replace the existing context menu button:

```swift
Button("Desactivar", systemImage: "minus.circle", role: .destructive) {
    Task { await disable(block.id) }
}
```

With:

```swift
Button("Desactivar", systemImage: "minus.circle", role: .destructive) {
    let resolver = CapabilityDependencyResolver()
    let blockers = resolver.dependents(of: block.id, in: enabledIds)
    if blockers.isEmpty {
        Task { await disable(block.id) }
    } else {
        cascadeAlert = CascadeAlertContext(targetId: block.id, dependents: blockers)
    }
}
```

- [ ] **Step 3: Attach the alert**

Add `.alert(...)` modifier on the navigation stack body:

```swift
.alert(
    "Esto desactivará también:",
    isPresented: alertBinding,
    presenting: cascadeAlert
) { ctx in
    Button("Desactivar todas", role: .destructive) {
        Task { await disableCascade(ctx.targetId, dependents: ctx.dependents) }
    }
    Button("Cancelar", role: .cancel) {}
} message: { ctx in
    Text(ctx.dependents.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
}
```

And:

```swift
private var alertBinding: Binding<Bool> {
    Binding(
        get: { cascadeAlert != nil },
        set: { if !$0 { cascadeAlert = nil } }
    )
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
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift && \
git commit -m "$(cat <<'EOF'
feat(capability): cascade-disable alert for dependents

Disabling rsvp while check_in is on now triggers an alert listing the
dependents. User chooses "Desactivar todas" (cascade) or "Cancelar".
No more silent dependency breakage.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 7: Wire dependency CTA on enable

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift`

**Why:** Enabling check_in when rsvp is off creates an invalid state. Show "Esta capability requiere X" with a "Activar también" CTA.

- [ ] **Step 1: Add state + alert**

```swift
@State private var enableAlert: EnableAlertContext?

private struct EnableAlertContext: Identifiable {
    let id = UUID()
    let targetId: String
    let missing: [String]
}
```

- [ ] **Step 2: Intercept the enable tap**

Replace:

```swift
Button {
    Task { await enable(block.id) }
} label: { ... }
```

With:

```swift
Button {
    let resolver = CapabilityDependencyResolver()
    let missing = resolver.missingDependencies(of: block.id, in: enabledIds)
    if missing.isEmpty {
        Task { await enable(block.id) }
    } else {
        enableAlert = EnableAlertContext(targetId: block.id, missing: missing)
    }
} label: { ... }
```

- [ ] **Step 3: Attach the second alert**

```swift
.alert(
    "Activar también:",
    isPresented: enableAlertBinding,
    presenting: enableAlert
) { ctx in
    Button("Activar todas") {
        Task { await enableCascade(ctx.targetId, missing: ctx.missing) }
    }
    Button("Cancelar", role: .cancel) {}
} message: { ctx in
    Text(ctx.missing.compactMap { CapabilityCatalog.v1.byId[$0]?.displayName }.joined(separator: ", "))
}
```

And:

```swift
private var enableAlertBinding: Binding<Bool> {
    Binding(
        get: { enableAlert != nil },
        set: { if !$0 { enableAlert = nil } }
    )
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
```

- [ ] **Step 4: Build + commit + tag Pass 2**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ManageCapabilitiesSheet.swift && \
git commit -m "$(cat <<'EOF'
feat(capability): cascade-enable alert for missing dependencies

Enabling check_in while rsvp is off now triggers an alert listing the
missing dependencies. User chooses "Activar todas" (cascade) or
"Cancelar". Completes dependency cascade UX for both directions.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)" && \
git tag -a level5-pass2-complete -m "Level 5 redesign — Pass 2 (dependency cascade UX) complete"
```

---

## Done When

- All 7 tasks committed.
- `EnableCapabilitySheet` deleted; `ManageCapabilitiesSheet` is the single entry.
- Disable available with cascade-aware alert.
- Per-capability config editable post-creation via `EditCapabilityConfigSheet`.
- Enable shows "Activar también" CTA when dependencies are missing.
- Build clean.
- Two tags: `level5-pass1-complete`, `level5-pass2-complete`.

---

## Out of Scope

- Pass 3 (member capability overrides UI)
- Pass 4 (missing section views: Voting, Ledger, Appeal, Assignment)
- Realtime catalog sync (server → client)
- `capabilityToggled` / `capabilityConfigUpdated` atoms exposed in activity feed
- Conflict detection (catalog has no conflicts field yet — only dependencies)
- Cross-resource capability constraints (e.g., "this fund's voting threshold must be ≥ the group default")
