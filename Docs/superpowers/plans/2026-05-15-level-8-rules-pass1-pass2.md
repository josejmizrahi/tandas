# Level 8 Rules Management — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make existing rules editable (params), surface scope picker in the builder, and enable resource-scoped rule creation from `ResourceRulesSheet`.

**Architecture:** Two sequential passes. Pass 1 adds an "Editar parámetros" flow that reuses the builder's param-form via a new coordinator + sheet. Pass 2 unhides the scope picker step in `RuleBuilderCoordinator` and wires "+" on `ResourceRulesSheet` with `initialScope: .resource(id)`.

**Tech Stack:** SwiftUI iOS 26+, Swift 6.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-8-rules-management.md`.

---

## Verified facts (use directly)

- `RuleTemplateScope` at `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/RuleTemplate.swift:90` has cases `.group`, `.resource(UUID)`, `.series(UUID)`. Already serializes to `{type, id}` JSONConfig.
- `RuleBuilderCoordinator.Phase: { templatePick, paramFill, publish }` (3 cases — adding `scopePick` = new case).
- `RuleBuilderCoordinator.scope: RuleTemplateScope = .group` (default, never mutated by UI today).
- `EditRuleSheet` ALREADY EXISTS at `Features/Rules/EditRuleSheet.swift` (170 L). Only edits flat amount + repeal vote. Our new "edit params" sheet must use a different name — use `EditRuleParamsSheet`.
- `RuleTemplateRepository.publishRuleVersion(groupId:templateId:params:scope:title:reason:)` exists (line 28 of repo).
- `Rule` model has `slug` (template id), `name`, `trigger`, `conditions`, `consequences`, `resourceId`, `seriesId`.
- `GroupRule` is read-side (consequences as envelopes). `RuleBuilderTemplate` carries `composition` + `defaultParams`.
- Modal policy: `.fullScreenCover`. Token names: `RuulRadius.lg`/`.md`, etc.

---

## Pass 1 — Edit existing rule params (Tasks 1-4)

### Task 1: Create `EditRuleParamsCoordinator`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRuleParamsCoordinator.swift`

Write:

```swift
import Foundation
import Observation
import OSLog
import RuulCore
import RuulUI

@Observable
@MainActor
public final class EditRuleParamsCoordinator: Identifiable {
    public let id = UUID()
    public let rule: Rule
    public let template: RuleBuilderTemplate
    private let ruleTemplateRepo: any RuleTemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rule.edit-params")

    public var paramValues: [String: JSONConfig]
    public var isSaving: Bool = false
    public var error: CoordinatorError?
    /// True when save succeeded; caller dismisses + refreshes the list.
    public var didSave: Bool = false

    public init(
        rule: Rule,
        template: RuleBuilderTemplate,
        ruleTemplateRepo: any RuleTemplateRepository
    ) {
        self.rule = rule
        self.template = template
        self.ruleTemplateRepo = ruleTemplateRepo
        // Hydrate from the rule's existing trigger/conditions/consequences
        // configs. They follow the same shape as the builder's
        // [String: JSONConfig] dict — each `field.key` maps to its current
        // value across the trigger + condition + consequence configs.
        self.paramValues = Self.extractParams(from: rule)
    }

    public func save(scope: RuleTemplateScope) async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            _ = try await ruleTemplateRepo.publishRuleVersion(
                groupId: rule.groupId,
                templateId: template.id,
                params: paramValues,
                scope: scope,
                title: rule.name,
                reason: "Editar parámetros"
            )
            didSave = true
        } catch {
            log.warning("rule params save failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar los cambios")
        }
    }

    public func clearError() { error = nil }

    /// Walks the rule's trigger.config + conditions[].config + consequences[].config
    /// and flattens to a single [String: JSONConfig] keyed by JSON object key.
    private static func extractParams(from rule: Rule) -> [String: JSONConfig] {
        var out: [String: JSONConfig] = [:]
        // Trigger config
        if case .object(let dict) = rule.trigger.config.asJSON() {
            for (k, v) in dict { out[k] = v }
        }
        // Conditions
        for cond in rule.conditions {
            if case .object(let dict) = cond.config.asJSON() {
                for (k, v) in dict { out[k] = v }
            }
        }
        // Consequences
        for cons in rule.consequences {
            if case .object(let dict) = cons.config.asJSON() {
                for (k, v) in dict { out[k] = v }
            }
        }
        return out
    }
}
```

NOTE: `JSONConfig.asJSON()` — verify exists. If absent, JSONConfig may already BE the json value (single-value or .object). If so, replace `cond.config.asJSON()` with `cond.config` directly. Adapt to whatever the existing `RuleBuilderCoordinator` does to assemble params (read `RuleBuilderCoordinator.swift` to see the pattern).

Build + commit:

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRuleParamsCoordinator.swift && \
git commit -m "$(cat <<'EOF'
feat(rules): EditRuleParamsCoordinator — load + save rule params

Hydrates paramValues from the rule's existing trigger/conditions/
consequences configs. Save calls publishRuleVersion with the rule's
existing template_id + new params → new rule_versions row supersedes.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

### Task 2: Create `EditRuleParamsSheet`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRuleParamsSheet.swift`

Write the sheet that hosts the param form. **First inspect** how `RuleBuilderView` renders the paramFill step:

```bash
grep -n "paramFill\|composedFields\|BuilderField\|fieldsForTemplate" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleBuilderView.swift | head -15
```

The fields likely come from `template.composition.parts.flatMap { $0.requiredFields + $0.optionalFields }` (or similar — confirm). Reuse the SAME field-resolution function.

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct EditRuleParamsSheet: View {
    @Bindable var coordinator: EditRuleParamsCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: EditRuleParamsCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    private var fields: [BuilderField] {
        // Same field resolution the builder uses. If RuleBuilderView has a
        // private helper `fields(for:)`, lift it to a fileprivate global
        // in this file too OR call a static helper if one exists on
        // RuleBuilderTemplate / RuleShapeRegistry.
        // Fallback: union of all shape fields in the composition.
        coordinator.template.composition.parts.flatMap { part in
            part.requiredFields + part.optionalFields
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    Text(coordinator.rule.name)
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if fields.isEmpty {
                        Text("Esta regla no tiene parámetros editables.")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextTertiary)
                    } else {
                        VStack(spacing: RuulSpacing.md) {
                            ForEach(fields, id: \.key) { field in
                                BuilderFieldRenderer(field: field, values: $coordinator.paramValues)
                            }
                        }
                    }
                    if let error = coordinator.error {
                        Text(error.message)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Editar regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isSaving ? "Guardando…" : "Guardar") {
                        Task {
                            let scope = scopeForRule(coordinator.rule)
                            await coordinator.save(scope: scope)
                            if coordinator.didSave { dismiss() }
                        }
                    }
                    .disabled(coordinator.isSaving)
                }
            }
        }
    }

    /// Reconstructs the scope from the rule's resourceId/seriesId.
    /// New scopes (via Pass 2) would come from a picker; for now we preserve.
    private func scopeForRule(_ rule: Rule) -> RuleTemplateScope {
        if let id = rule.seriesId { return .series(id) }
        if let id = rule.resourceId { return .resource(id) }
        return .group
    }
}
```

NOTES: `BuilderField`, `BuilderFieldRenderer`, `RuleBuilderTemplate.composition.parts.requiredFields/optionalFields` — confirm exact names. If `composition` shape differs (e.g., flat `triggerShapeId/conditionShapeIds[]/consequenceShapeIds[]` instead of `parts: [Part]`), resolve fields via `RuleShapeRegistry.byId[shapeId]?.configFields`. Adapt accordingly.

Build + commit (skip the boilerplate for brevity in subsequent tasks).

### Task 3: Wire "Editar parámetros" in `RuleDetailView`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleDetailView.swift`

Add a navrow row (admin-only) that presents `EditRuleParamsSheet`:

```swift
@State private var paramsCoordinator: EditRuleParamsCoordinator?

// In the body, under existing admin actions:
if canEditRules, let template = templateForRule {
    Button {
        paramsCoordinator = EditRuleParamsCoordinator(
            rule: rule,
            template: template,
            ruleTemplateRepo: app.ruleTemplateRepo
        )
    } label: {
        Label("Editar parámetros", systemImage: "slider.horizontal.3")
    }
}

// And:
.fullScreenCover(item: $paramsCoordinator) { coord in
    EditRuleParamsSheet(coordinator: coord)
        .environment(app)
}
```

Where `templateForRule: RuleBuilderTemplate?` is a computed:
```swift
private var templateForRule: RuleBuilderTemplate? {
    app.ruleTemplates.first(where: { $0.id == rule.slug })
}
```

Confirm `app.ruleTemplates` exists or use `RuleTemplateRegistry`. If not present, inject `templates: [RuleBuilderTemplate]` through the view init.

### Task 4: Block edit when pending vote exists

In `RuleDetailView.swift`, before showing the "Editar parámetros" button, check `rulesCoordinator.pendingRepealVote(rule.id) != nil` (whichever check is already in use for the existing flat-amount edit). If pending, show disabled state with subtitle "Hay un cambio en votación — espera al resultado".

Build + commit + tag:

```bash
git tag -a level8-pass1-complete -m "Level 8 redesign — Pass 1 (edit rule params) complete"
```

---

## Pass 2 — Scope picker + resource-scoped creation (Tasks 5-7)

### Task 5: Add `scopePick` phase to `RuleBuilderCoordinator`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleBuilderCoordinator.swift`

Update the `Phase` enum:

```swift
public enum Phase: Equatable, Sendable {
    case templatePick
    case scopePick   // NEW
    case paramFill
    case publish
}
```

Add `initialScope: RuleTemplateScope?` param to init. If provided, the coordinator skips `scopePick` and uses it directly. Update `advance(...)` transitions so `templatePick → scopePick → paramFill → publish`, but if `initialScope != nil` go straight `templatePick → paramFill`.

Add a public mutator `selectScope(_ scope: RuleTemplateScope)` that sets `self.scope` and advances to `paramFill`.

### Task 6: Render scope picker step in `RuleBuilderView`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleBuilderView.swift`

Add a `scopePickStep` view rendered when `coordinator.phase == .scopePick`:

```swift
@ViewBuilder
private var scopePickStep: some View {
    VStack(alignment: .leading, spacing: RuulSpacing.md) {
        Text("¿Dónde aplica esta regla?")
            .ruulTextStyle(RuulTypography.title)
            .foregroundStyle(Color.ruulTextPrimary)

        scopeRow(label: "Todo el grupo",
                 subtitle: "Aplica a todos los recursos del grupo.",
                 isSelected: coordinator.scope == .group,
                 action: { coordinator.selectScope(.group) })

        // Only show resource/series rows when the host has a context — i.e.
        // when the builder was opened from a resource detail and initialScope
        // suggested one of them. For Beta-1 builder-from-Acuerdos (no resource
        // context), only `.group` is selectable.
        // The other rows are deferred — the resource-scoped path uses
        // initialScope skip-step (see Task 7).
    }
    .padding(RuulSpacing.lg)
}

private func scopeRow(label: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundStyle(isSelected ? Color.ruulAccent : Color.ruulTextTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    }
    .buttonStyle(.plain)
}
```

Plug into the existing switch over phases. If you find the existing switch (it's in the body), add a `.scopePick: scopePickStep` case.

### Task 7: Wire "+" in resource rules surface

**Files:**
- Modify: `ResourceRulesSheet` OR equivalent (find with `grep -rn "ResourceRulesSheet\b" ios/Packages/RuulFeatures/Sources --include='*.swift' | head -5`).

Add a toolbar `+` button (admin-only) that presents `RuleBuilderView` with `initialScope: .resource(resource.id)`. Confirm `RuleBuilderView` has an init that accepts `initialScope` — if not, add it (passing through to the coordinator).

```swift
ToolbarItem(placement: .topBarTrailing) {
    if canEditRules {
        Button(action: { showBuilder = true }) {
            Image(systemName: "plus")
        }
    }
}
.fullScreenCover(isPresented: $showBuilder) {
    RuleBuilderView(
        groupId: resource.groupId,
        initialScope: .resource(resource.id)
    )
    .environment(app)
}
```

Build + commit + tag:

```bash
xcodebuild ... | tail -3
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleBuilderCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/RuleBuilderView.swift \
        $(grep -rln "ResourceRulesSheet\b" ios/Packages/RuulFeatures/Sources --include='*.swift') && \
git commit -m "..." && \
git tag -a level8-pass2-complete -m "Level 8 redesign — Pass 2 (scope picker + resource-scoped creation) complete"
```

---

## Done When

- 7 tasks committed (4 Pass 1 + 3 Pass 2).
- Tap "Editar parámetros" on `RuleDetailView` (admin-only) → `EditRuleParamsSheet` opens with current params hydrated.
- Save → calls `publishRuleVersion` with same templateId + new params → new `rule_versions` row.
- `RuleBuilderView` has a scope picker step between template and params.
- `ResourceRulesSheet` toolbar "+" opens the builder with `initialScope: .resource(id)` and skips the scope step.
- Build clean.
- Two tags: `level8-pass1-complete`, `level8-pass2-complete`.

---

## Out of Scope

- Pass 3 (conflicts blocking + audit feed visibility)
- Pass 4 (per-piece builder, shape pickers public)
- Pass 5 (`member_capability_overrides` UI)
- Pass 6 (`rule_evaluations` debug visibility)
- Series scope picker UI (deferred — needs series_id resolution from active resource)
- Cross-group rule import/export
