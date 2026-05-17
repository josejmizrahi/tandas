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

    public init(coordinator: EditRuleParamsCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
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
                        VStack(spacing: RuulSpacing.sm) {
                            ForEach(coordinator.sortedParamKeys, id: \.self) { key in
                                EditParamField(
                                    key: key,
                                    value: coordinator.paramInt(key) ?? 0,
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

/// Stepper-based param editor. Mirrors `ParamField` from `RuleBuilderView`
/// (private there, lifted here so `EditRuleParamsSheet` can reuse the same
/// UX without touching the builder files).
private struct EditParamField: View {
    let key: String
    let value: Int
    let onChange: (Int) -> Void

    @State private var local: Int

    init(key: String, value: Int, onChange: @escaping (Int) -> Void) {
        self.key = key
        self.value = value
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

    private var label: String {
        switch key {
        case "amount":            return "Monto de la multa"
        case "minutes":           return "Tolerancia"
        case "hours":             return "Anticipación"
        case "threshold_cents":   return "Umbral del gasto"
        case "duration_hours":    return "Duración del voto"
        case "quorum_percent":    return "Quórum mínimo"
        case "threshold_percent": return "Umbral para pasar"
        default:                  return key.capitalized.replacingOccurrences(of: "_", with: " ")
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
        default:                  return ""
        }
    }

    private var range: ClosedRange<Int> {
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
