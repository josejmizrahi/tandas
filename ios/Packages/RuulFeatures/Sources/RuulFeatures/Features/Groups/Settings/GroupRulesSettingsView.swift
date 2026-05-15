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
public struct GroupRulesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Bindable var coordinator: GroupRulesCoordinator

    public init(coordinator: GroupRulesCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    public var body: some View {
        NavigationStack {
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
                            ("¿Quién puede cambiar los acuerdos del grupo?",
                                coordinator.humanAnswer(for: .ruleUpdateAmount),
                                /*isLive*/ true),
                            ("¿Quién puede agregar acuerdos nuevos?",
                                coordinator.humanAnswer(for: .ruleCreate),
                                true),
                            ("¿Quién puede borrar acuerdos?",
                                coordinator.humanAnswer(for: .ruleDelete),
                                true),
                            ("¿Quién puede activar/desactivar acuerdos?",
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

                    section(title: "Dinero", subtitle: "Reglas financieras globales del grupo.") {
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
            .ruulAmbientScreen(palette: app.activeGroup?.ambientPalette)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Gobierno del grupo")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
            .task { await coordinator.refresh() }
        }
    }

    // MARK: - Intro

    /// One-line framing so users get the doctrine without reading docs:
    /// these rules gobiernan el GRUPO, not the cenas. Keeps the screen
    /// from being confused with the Acuerdos surface.
    private var intro: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("Cómo funciona este grupo")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Las reglas de cada cosa (multas, llegadas, RSVP) viven en Acuerdos. Esto es el sistema.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
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
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
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
                    .foregroundStyle(isActive ? Color.ruulAccent : Color.ruulTextTertiary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(preset.subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                if coordinator.isSaving && isActive {
                    ProgressView().scaleEffect(0.7).tint(Color.ruulAccent)
                }
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(isActive ? Color.ruulAccent : Color.ruulSeparator, lineWidth: 1)
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
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(subtitle)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
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
                        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
                    }
                    HStack(alignment: .top, spacing: RuulSpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            if !entry.isLive {
                                Text("Próximamente")
                                    .ruulTextStyle(RuulTypography.sectionLabel)
                                    .foregroundStyle(Color.ruulTextTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.answer)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(entry.isLive ? Color.ruulTextPrimary : Color.ruulTextSecondary)
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
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }
}
