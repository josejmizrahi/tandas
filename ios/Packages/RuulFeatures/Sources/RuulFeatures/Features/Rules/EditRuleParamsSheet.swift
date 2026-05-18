import SwiftUI
import RuulUI
import RuulCore

/// Sheet that lets a group admin edit the parameters of an existing rule.
/// Reuses the same param keys and `ParamField` widget the Rule Builder
/// uses in its `paramFill` phase. Presented as a `.fullScreenCover` from
/// `RuleDetailView`.
///
/// Field resolution: `RuleBuilderTemplate.composition` is a flat shape-id
/// tuple (no `parts`). The canonical param keys come from
/// `coordinator.sortedParamKeys` which mirrors `ParamFormView.paramKeys()`
/// (derived from `template.defaultParams` merged with the rule's configs).
///
/// Save calls `publishRuleVersion` → new `rule_versions` row supersedes the
/// current one. Caller dismisses + refreshes the rule list on `didSave`.
@MainActor
public struct EditRuleParamsSheet: View {
    @Bindable var coordinator: EditRuleParamsCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    public init(coordinator: EditRuleParamsCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    /// Resolves the per-key `RuleShapeField` metadata by walking the
    /// template's composition (trigger + condition + consequence shape ids)
    /// and indexing every shape's `configFields` by key. Lets the
    /// EditParamField use catalog-backed min/max/defaults instead of the
    /// hardcoded switch — declarative-first per founder principle
    /// 2026-05-10 (runtime catalog wins for numeric metadata; curated
    /// Spanish labels in the switch stay as the copy source until the
    /// shape catalog's label_es is upgraded to match).
    private var fieldsByKey: [String: RuleShapeField] {
        var out: [String: RuleShapeField] = [:]
        let registry = app.ruleShapeRegistry
        let composition = coordinator.template.composition
        var shapeIds: [String] = [composition.triggerShapeId]
        shapeIds.append(contentsOf: composition.conditionShapeIds)
        shapeIds.append(contentsOf: composition.consequenceShapeIds)
        for sid in shapeIds {
            guard let shape = registry.shape(id: sid) else { continue }
            for field in shape.configFields {
                out[field.key] = field
            }
        }
        return out
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    // Context header
                    VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                        Text(coordinator.template.displayNameES)
                            .font(.title3).fontWeight(.semibold)
                        Text(coordinator.template.descriptionES)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Param fields
                    if coordinator.sortedParamKeys.isEmpty {
                        Text("Esta regla no tiene parámetros editables.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        let resolved = fieldsByKey
                        VStack(spacing: RuulSpacing.sm) {
                            ForEach(coordinator.sortedParamKeys, id: \.self) { key in
                                EditParamField(
                                    key: key,
                                    value: coordinator.paramInt(key) ?? 0,
                                    field: resolved[key],
                                    onChange: { newVal in coordinator.setParam(key, intValue: newVal) }
                                )
                            }
                        }
                    }

                    // Error banner
                    if let error = coordinator.error {
                        ErrorBannerView(error: error)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .ruulSheetToolbar("Editar parámetros")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isSaving ? "Guardando…" : "Guardar") {
                        Task {
                            let scope = scopeForRule(coordinator.rule)
                            await coordinator.save(scope: scope)
                            if coordinator.didSave { dismiss() }
                        }
                    }
                    .disabled(coordinator.isSaving)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Reconstructs the scope from the rule's resourceId/seriesId.
    /// Pass 2 adds a scope picker; for now we preserve the existing scope.
    private func scopeForRule(_ rule: GroupRule) -> RuleTemplateScope {
        if let id = rule.seriesId  { return .series(id) }
        if let id = rule.resourceId { return .resource(id) }
        return .group
    }
}

// MARK: - EditParamField

/// Stepper-based param editor. Hybrid declarative/curated per
/// UniversalRuleTemplates.md §9.1 — numeric metadata (min, max) comes
/// from the rule_shapes catalog when present so future shape additions
/// inherit correct ranges automatically; Spanish labels + units +
/// formatting stay curated per universal key (catalog copy is less
/// polished today, doctrine §15 forbids hardcoded *vertical* logic,
/// not curated *per-key* copy).
private struct EditParamField: View {
    let key: String
    let value: Int
    let field: RuleShapeField?
    let onChange: (Int) -> Void

    @State private var local: Int

    init(
        key: String,
        value: Int,
        field: RuleShapeField? = nil,
        onChange: @escaping (Int) -> Void
    ) {
        self.key = key
        self.value = value
        self.field = field
        self.onChange = onChange
        _local = State(initialValue: value)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: $local, in: range, step: step) {
                Text(format(local))
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .onChange(of: local) { _, newVal in onChange(newVal) }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 14))
    }

    /// Curated per-key label (more refined than the catalog's `label_es`
    /// today, e.g. "Tolerancia" vs catalog's "Minutos de tolerancia").
    /// When a future migration upgrades catalog copy, drop the switch
    /// and read `field?.labelES` directly.
    private var label: String {
        switch key {
        case "amount":            return "Monto de la multa"
        case "minutes":           return "Tolerancia"
        case "hours":             return "Anticipación"
        case "threshold_cents":   return "Umbral del gasto"
        case "duration_hours":    return "Duración del voto"
        case "quorum_percent":    return "Quórum mínimo"
        case "threshold_percent": return "Umbral para pasar"
        default:
            // Last resort: the catalog's label_es if present, else
            // a humanized key. Keeps the form usable when a shape
            // adds a new param the curated switch doesn't know yet.
            if let f = field { return f.labelES }
            return key.capitalized.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var unit: String {
        switch key {
        case "amount":            return "MXN — pesos mexicanos"
        case "minutes":           return "minutos después de la hora"
        case "hours":             return "horas antes del evento"
        case "threshold_cents":   return "MXN — el voto se dispara arriba de este monto"
        case "duration_hours":    return "horas que el voto sigue abierto"
        case "quorum_percent":    return "% de miembros que deben votar para que cuente"
        case "threshold_percent": return "% de votos a favor (vs total) para que pase"
        default:                  return field?.placeholder ?? ""
        }
    }

    /// Catalog-first range. When the shape declares min/max in
    /// config_fields (new shapes added server-side automatically inherit
    /// correct bounds), use that; otherwise fall back to the curated
    /// per-key range below.
    private var range: ClosedRange<Int> {
        if let f = field, let min = f.min, let max = f.max, min <= max {
            return min...max
        }
        switch key {
        case "amount":            return 50...10_000
        case "minutes":           return 0...120
        case "hours":             return 1...168
        case "threshold_cents":   return 50_000...100_000_000
        case "duration_hours":    return 1...168
        case "quorum_percent":    return 0...100
        case "threshold_percent": return 0...100
        default:                  return 0...1_000_000
        }
    }

    /// Catalog doesn't declare step today; keep curated per-key step
    /// since steppers below 5%/$50 are noisy on touch.
    private var step: Int {
        switch key {
        case "amount":            return 50
        case "minutes":           return 5
        case "hours":             return 1
        case "threshold_cents":   return 50_000
        case "duration_hours":    return 6
        case "quorum_percent":    return 5
        case "threshold_percent": return 5
        default:                  return 1
        }
    }

    private func format(_ v: Int) -> String {
        switch key {
        case "amount":            return "$\(v)"
        case "minutes":           return "\(v) min"
        case "hours":             return "\(v) h"
        case "threshold_cents":   return "$\(v / 100)"
        case "duration_hours":    return "\(v) h"
        case "quorum_percent":    return "\(v)%"
        case "threshold_percent": return "\(v)%"
        default:                  return String(v)
        }
    }
}

// MARK: - ErrorBannerView

private struct ErrorBannerView: View {
    let error: CoordinatorError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.title)
                    .font(.subheadline.weight(.semibold))
            }
            if let m = error.message {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
