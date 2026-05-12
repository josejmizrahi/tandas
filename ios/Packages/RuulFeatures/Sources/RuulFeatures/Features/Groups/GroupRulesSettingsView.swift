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

                    section(title: "Permisos", subtitle: "Quién puede hacer qué.") {
                        previewList([
                            ("¿Quién puede crear recursos?", currentPresetMatches ? "Cualquiera" : "Configurable"),
                            ("¿Quién puede invitar miembros?", "Cualquiera"),
                            ("¿Quién puede activar capabilities?", "Admin"),
                            ("¿Quién puede borrar recursos?", "Admin"),
                            ("¿Quién administra los fondos?", "Admin"),
                        ])
                    }

                    section(title: "Miembros", subtitle: "Cómo funciona la membresía y los invitados.") {
                        previewList([
                            ("¿Miembros nuevos requieren aprobación?", "No"),
                            ("¿Cuántos invitados máximo por miembro?", "Sin límite"),
                            ("¿Los invitados pueden votar?", "No"),
                            ("¿Los invitados ven el dinero?", "No"),
                        ])
                    }

                    section(title: "Dinero", subtitle: "Reglas financieras globales del grupo.") {
                        previewList([
                            ("¿Los balances son visibles para todos?", "Sí"),
                            ("¿Gastos arriba de cuánto necesitan aprobación?", "Sin límite"),
                            ("¿Los retiros de fondos necesitan votación?", "No"),
                            ("¿Cuándo mandan recordatorios de pago?", "48 hrs"),
                        ])
                    }

                    section(title: "Visibilidad", subtitle: "Quién puede ver qué.") {
                        previewList([
                            ("¿Los invitados ven balances?", "No"),
                            ("¿Quién ve analíticas del grupo?", "Solo admin"),
                            ("¿Los settlements son privados?", "No"),
                        ])
                    }

                    section(title: "Defaults para recursos nuevos", subtitle: "Sugerencias que heredan las cosas nuevas.") {
                        previewList([
                            ("¿Eventos nuevos sugieren RSVP?", "Sí"),
                            ("¿Gastos nuevos tienen deadline?", "72 hrs"),
                            ("¿Bookings nuevos requieren confirmación?", "No"),
                        ])
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
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

    /// Whether any preset matched the current policies — used as a
    /// heuristic seed for the read-only previews until V2 wires real
    /// per-question editing.
    private var currentPresetMatches: Bool { coordinator.activePreset != nil }

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

    /// Read-only Q&A list for sections that haven't been wired to live
    /// per-question editing yet. Each row reads as a humanized question
    /// + current answer — never exposing `policy_type` / `target_action`
    /// jargon. Tap target later opens a per-question editor.
    private func previewList(_ entries: [(question: String, answer: String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                VStack(spacing: 0) {
                    if idx > 0 {
                        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
                    }
                    HStack(alignment: .top, spacing: RuulSpacing.sm) {
                        Text(entry.question)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.answer)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextSecondary)
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
        .overlay(alignment: .topTrailing) {
            Text("Próximamente editable")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xs)
                .padding(.vertical, 2)
                .background(Color.ruulSurface, in: Capsule())
                .padding(RuulSpacing.xs)
        }
    }
}
