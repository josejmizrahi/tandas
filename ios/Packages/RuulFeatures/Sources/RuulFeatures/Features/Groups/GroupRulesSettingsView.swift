import SwiftUI
import RuulUI
import RuulCore

/// Group Rules settings — the 6 sections from the governance spec. V1 only
/// edits the "How decisions are made" section via preset. The other 5
/// sections surface as cards with "Próximamente" so the founder can see
/// the shape of what's coming without leaving the screen.
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
                    section(
                        title: "Cómo se toman decisiones",
                        subtitle: "Quién puede cambiar las reglas y si los cambios necesitan votación."
                    ) {
                        presetPicker
                    }

                    placeholderSection(
                        title: "Quién puede qué",
                        subtitle: "Crear resources, invitar miembros, aprobar invitados."
                    )
                    placeholderSection(
                        title: "Defaults para resources nuevos",
                        subtitle: "RSVP sugerido, deadlines, confirmación."
                    )
                    placeholderSection(
                        title: "Reglas de miembros",
                        subtitle: "Aprobación, deuda máxima, suspensión."
                    )
                    placeholderSection(
                        title: "Reglas de dinero",
                        subtitle: "Gastos grandes, withdrawals, recordatorios."
                    )
                    placeholderSection(
                        title: "Invitados",
                        subtitle: "Aprobación, máximos, visibilidad."
                    )
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
                    Text("Reglas del grupo")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
            .task { await coordinator.refresh() }
        }
    }

    // MARK: - Preset picker

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

    private func placeholderSection(title: String, subtitle: String) -> some View {
        section(title: title, subtitle: subtitle) {
            HStack {
                Text("Próximamente")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface.opacity(0.5))
            )
        }
    }
}
