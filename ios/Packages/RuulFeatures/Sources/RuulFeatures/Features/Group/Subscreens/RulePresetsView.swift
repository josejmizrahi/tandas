import SwiftUI
import RuulUI
import RuulCore

/// Group governance settings — the social-system layer. NOT behavior rules
/// (those live under "Acuerdos" / RulesView). Doctrine: keeps the group
/// from becoming an ERP. See memory/project_group_governance_rules.md.
///
/// Six sections in importance order: Decisions → Permissions → Members →
/// Money → Visibility → Defaults. V1 only edits Decisions (via preset);
/// the other five render the human Q&A but their answers are read-only
/// previews until per-question editing ships in V2.
public struct RulePresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Bindable var coordinator: GroupRulesCoordinator

    public init(coordinator: GroupRulesCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                intro

                section(title: "Decisiones", subtitle: "Cómo se toman cambios importantes.") {
                    presetPicker
                }

                // Show ONLY questions backed by a real target_action.
                // Doctrine: don't advertise what we don't deliver. As
                // new actions land (member.invite, fund.withdraw,
                // visibility.*, defaults.*) the corresponding rows
                // re-appear here.

                section(title: "Permisos", subtitle: "Quién puede hacer qué.") {
                    liveList([
                        ("¿Quién puede cambiar las reglas del grupo?",
                            coordinator.humanAnswer(for: .ruleUpdateAmount),
                            /*isLive*/ true),
                        ("¿Quién puede agregar reglas nuevas?",
                            coordinator.humanAnswer(for: .ruleCreate),
                            true),
                        ("¿Quién puede borrar reglas?",
                            coordinator.humanAnswer(for: .ruleDelete),
                            true),
                        ("¿Quién puede activar/desactivar reglas?",
                            coordinator.humanAnswer(for: .ruleToggle),
                            true),
                        // Beta 1 W2-C1: "capabilities" → "funciones nuevas".
                        ("¿Quién puede activar funciones nuevas?",
                            coordinator.humanAnswer(for: .capabilityEnable),
                            true),
                    ])
                }

                section(title: "Miembros", subtitle: "Cómo se quita / agrega gente.") {
                    liveList([
                        ("¿Quién puede invitar miembros?",
                            coordinator.humanAnswer(for: .memberInvite),
                            true),
                        ("¿Cómo se quita a alguien del grupo?",
                            coordinator.humanAnswer(for: .memberRemove),
                            true),
                    ])
                }

                section(title: "Dinero", subtitle: "Política financiera global del grupo.") {
                    liveList([
                        ("¿Quién puede registrar gastos?",
                            coordinator.humanAnswer(for: .expenseCreate),
                            true),
                    ])
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
        .ruulSheetToolbar("Gobierno del grupo")
        .task { await coordinator.refresh() }
    }

    // MARK: - Intro

    /// One-line framing so users get the doctrine without reading docs:
    /// these presets gobiernan el GRUPO (quién puede modificar qué,
    /// quórum de votos, etc.), no los acuerdos del día a día.
    private var intro: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("Cómo decide este grupo")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Esto define quién puede cambiar las cosas y cómo se vota. Las reglas concretas (multas, llegadas, RSVP) viven en Reglas.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Preset picker (Decisiones)

    private var presetPicker: some View {
        VStack(spacing: RuulSpacing.sm) {
            ForEach(GroupPolicyPreset.all) { preset in
                presetCard(preset)
            }
            if let err = coordinator.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func presetCard(_ preset: GroupPolicyPreset) -> some View {
        let isActive = coordinator.activePreset?.id == preset.id
        return Button {
            Task { await coordinator.applyPreset(preset) }
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.ruulAccent : Color(.tertiaryLabel))
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                if coordinator.isSaving && isActive {
                    ProgressView().scaleEffect(0.7).tint(Color.ruulAccent)
                }
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(isActive ? Color.ruulAccent : Color(.separator), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isSaving)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // (Helper removed — per-question liveness is explicit per row now.)

    // MARK: - Section helpers

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .padding(.bottom, RuulSpacing.xs)
            content()
        }
    }

    /// Q&A list where each row carries its own "is live?" flag. Live rows
    /// read their answer from `group_policies` via the coordinator and
    /// surface a small "Activo" dot; non-live rows are placeholders for
    /// the V2 surface area and get a "Próximamente" tag. No "policy_type"
    /// jargon — every answer is a human sentence.
    private func liveList(_ entries: [(question: String, answer: String, isLive: Bool)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                VStack(spacing: 0) {
                    if idx > 0 {
                        Divider().background(Color(.separator)).padding(.leading, RuulSpacing.md)
                    }
                    HStack(alignment: .top, spacing: RuulSpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            if !entry.isLive {
                                Text("Próximamente")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.answer)
                            .font(.subheadline)
                            .foregroundStyle(entry.isLive ? Color.primary : Color.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, RuulSpacing.sm)
                    .padding(.horizontal, RuulSpacing.md)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulSurface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
