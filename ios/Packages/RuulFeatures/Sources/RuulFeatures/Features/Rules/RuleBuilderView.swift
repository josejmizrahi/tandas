import SwiftUI
import RuulCore
import RuulUI

/// Beta 1 Rule Builder — Template Gallery → Param Form → Publish.
/// Presented as a sheet from `RulesView`. The coordinator owns all state;
/// this view is a thin shell that routes by `coord.phase`.
///
/// Per Plans/Active/Governance.md §10 (Lego Rule Builder UX) — 3 fases
/// visibles para el usuario, sticky bottom sentence preview, no jargon.
public struct RuleBuilderView: View {
    @Bindable public var coord: RuleBuilderCoordinator
    let onDismiss: () -> Void

    public init(coord: RuleBuilderCoordinator, onDismiss: @escaping () -> Void) {
        self.coord = coord
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch coord.phase {
                case .templatePick:
                    TemplateGalleryView(coord: coord)
                case .paramFill:
                    ParamFormView(coord: coord)
                case .publish:
                    PublishReviewView(coord: coord)
                case .done(let result):
                    DoneView(result: result, onDismiss: onDismiss)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { handleCancel() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cerrar")
                }
            }
        }
    }

    private var navTitle: String {
        switch coord.phase {
        case .templatePick: return "Nueva regla"
        case .paramFill:    return coord.selectedTemplate?.displayNameES ?? "Personaliza"
        case .publish:      return "Revisa y publica"
        case .done:         return "Listo"
        }
    }

    private func handleCancel() {
        switch coord.phase {
        case .templatePick, .done:
            onDismiss()
        case .paramFill:
            coord.backToTemplatePick()
        case .publish:
            coord.backToParams()
        }
    }
}

// MARK: - Fase 1: Template Gallery

private struct TemplateGalleryView: View {
    @Bindable var coord: RuleBuilderCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("Elige el tipo de regla")
                    .font(.title3).fontWeight(.semibold)
                Text("Las reglas se aplican a todo el grupo. Puedes ajustar el monto y los detalles en el siguiente paso.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: RuulSpacing.sm) {
                    ForEach(coord.templates) { template in
                        TemplateCard(template: template) {
                            coord.selectTemplate(template)
                        }
                    }
                }

                if coord.templates.isEmpty {
                    ContentUnavailableView(
                        "Sin plantillas",
                        systemImage: "list.bullet.rectangle",
                        description: Text("No pudimos cargar el catálogo. Intenta más tarde.")
                    )
                    .padding(.top, RuulSpacing.xl)
                }
            }
            .padding(RuulSpacing.lg)
        }
    }
}

private struct TemplateCard: View {
    let template: RuleBuilderTemplate
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.displayNameES)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Text(template.descriptionES)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch template.id {
        case "late_arrival_fine":         return "clock.badge.exclamationmark"
        case "no_show_fine":              return "person.crop.circle.badge.xmark"
        case "same_day_cancel_fine":      return "calendar.badge.minus"
        case "no_rsvp_fine":              return "bell.slash"
        case "host_no_menu_fine":         return "fork.knife"
        case "expense_threshold_warning": return "dollarsign.circle"
        default:                          return "list.bullet.rectangle"
        }
    }
}

// MARK: - Fase 2: Param Form

private struct ParamFormView: View {
    @Bindable var coord: RuleBuilderCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                if let template = coord.selectedTemplate {
                    Text(template.descriptionES)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(spacing: RuulSpacing.sm) {
                        ForEach(paramKeys(), id: \.self) { key in
                            ParamField(
                                key: key,
                                value: coord.paramInt(key) ?? 0,
                                onChange: { newVal in coord.setParam(key, intValue: newVal) }
                            )
                        }
                    }
                }
            }
            .padding(RuulSpacing.lg)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PreviewFooter(
                summary: coord.preview,
                primaryTitle: "Revisar y publicar",
                primaryAction: { coord.goToReview() }
            )
        }
    }

    /// Stable, sorted param keys derived from the template's defaultParams
    /// so the form renders deterministically on every push.
    private func paramKeys() -> [String] {
        guard let template = coord.selectedTemplate else { return [] }
        if case .object(let dict) = template.defaultParams {
            return dict.keys.sorted { lhs, rhs in
                // amount first, then minutes/hours, then others alpha.
                let ranks = ["amount": 0, "threshold_cents": 0, "minutes": 1, "hours": 2]
                return (ranks[lhs] ?? 99, lhs) < (ranks[rhs] ?? 99, rhs)
            }
        }
        return []
    }
}

private struct ParamField: View {
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
        case "amount":          return "Monto de la multa"
        case "minutes":         return "Tolerancia"
        case "hours":           return "Anticipación"
        case "threshold_cents": return "Umbral del gasto"
        default:                return key.capitalized
        }
    }

    private var unit: String {
        switch key {
        case "amount":          return "MXN — pesos mexicanos"
        case "minutes":         return "minutos después de la hora"
        case "hours":           return "horas antes del evento"
        case "threshold_cents": return "MXN — el aviso se dispara arriba de este monto"
        default:                return ""
        }
    }

    private var range: ClosedRange<Int> {
        switch key {
        case "amount":          return 50...10_000
        case "minutes":         return 0...120
        case "hours":           return 1...168
        case "threshold_cents": return 50_000...100_000_000   // $500 - $1,000,000 in cents
        default:                return 0...1_000_000
        }
    }

    private var step: Int {
        switch key {
        case "amount":          return 50
        case "minutes":         return 5
        case "hours":           return 1
        case "threshold_cents": return 50_000   // $500 jumps
        default:                return 1
        }
    }

    private func format(_ v: Int) -> String {
        switch key {
        case "amount":          return "$\(v)"
        case "minutes":         return "\(v) min"
        case "hours":           return "\(v) h"
        case "threshold_cents": return "$\(v / 100)"
        default:                return String(v)
        }
    }
}

private struct PreviewFooter: View {
    let summary: String
    let primaryTitle: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(spacing: RuulSpacing.sm) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.tint)
                Text(summary)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 14))

            RuulButton(
                primaryTitle,
                style: .primary,
                size: .large,
                fillsWidth: true,
                action: primaryAction
            )
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.bottom, RuulSpacing.md)
        .padding(.top, RuulSpacing.sm)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Fase 3: Publish Review

private struct PublishReviewView: View {
    @Bindable var coord: RuleBuilderCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    Text("Así se aplicará")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(coord.previewDetail)
                        .font(.body)
                        .padding(RuulSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(in: .rect(cornerRadius: 14))
                }

                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    Text("¿Por qué este cambio? (opcional)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Ej. \"empezamos esta cena recurrente\"", text: $coord.changeReason, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .padding(RuulSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(in: .rect(cornerRadius: 14))
                }

                if let error = coord.error {
                    ErrorBanner(error: error)
                }
            }
            .padding(RuulSpacing.lg)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: RuulSpacing.sm) {
                RuulButton(
                    "Publicar regla",
                    systemImage: "checkmark.circle.fill",
                    style: .primary,
                    size: .large,
                    isLoading: coord.isPublishing,
                    fillsWidth: true,
                    action: { Task { await coord.publish() } }
                )
                RuulButton(
                    "Volver a editar",
                    style: .plain,
                    size: .medium,
                    fillsWidth: true,
                    action: { coord.backToParams() }
                )
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.md)
            .padding(.top, RuulSpacing.sm)
            .background(.ultraThinMaterial)
        }
    }
}

private struct ErrorBanner: View {
    let error: CoordinatorError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.title).font(.subheadline.weight(.semibold))
            }
            if let m = error.message {
                Text(m).font(.caption).foregroundStyle(.secondary)
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

// MARK: - Done

private struct DoneView: View {
    let result: RuleVersionPublishResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: result.ruleId)
            VStack(spacing: RuulSpacing.sm) {
                Text("Regla publicada")
                    .font(.title3).fontWeight(.semibold)
                Text("Aplica desde ahora. Vas a poder editar el monto o desactivarla en cualquier momento desde la lista de reglas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !result.conflicts.isEmpty {
                ConflictsList(conflicts: result.conflicts)
            }
            Spacer()
            RuulButton(
                "Cerrar",
                style: .primary,
                size: .large,
                fillsWidth: true,
                action: onDismiss
            )
        }
        .padding(RuulSpacing.lg)
    }
}

private struct ConflictsList: View {
    let conflicts: [RuleVersionConflict]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("Advertencias")
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(conflicts, id: \.againstRuleVersionId) { c in
                Text(conflictCopy(c))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private func conflictCopy(_ c: RuleVersionConflict) -> String {
        switch c.type {
        case "same_scope_overlapping":
            if let title = c.againstRuleTitle {
                return "Convive con otra regla activa: \"\(title)\". Ambas se evaluarán."
            }
            return "Convive con otra regla activa del mismo tipo."
        default:
            return c.type
        }
    }
}
