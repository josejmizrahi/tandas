import SwiftUI

/// Picker de vote_type. V1 enabled = generalProposal + ruleChange.
/// Los otros 5 visibles pero disabled con badge "próximamente".
/// Tap en enabled → push corresponding sheet.
struct CreateVoteSheet: View {
    var onPickGeneralProposal: () -> Void
    var onPickRuleChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                    Text("¿Qué quieres proponer?")
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .padding(.bottom, RuulSpacing.s2)

                    voteTypeCard(
                        title: "Propuesta general",
                        subtitle: "Texto libre — el grupo vota a favor o en contra.",
                        icon: "text.bubble",
                        enabled: true,
                        onTap: { dismiss(); onPickGeneralProposal() }
                    )

                    voteTypeCard(
                        title: "Cambio de regla",
                        subtitle: "Proponer cambiar el monto de una multa existente.",
                        icon: "list.bullet.clipboard",
                        enabled: true,
                        onTap: { dismiss(); onPickRuleChange() }
                    )

                    Text("PRÓXIMAMENTE")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .padding(.top, RuulSpacing.s5)

                    voteTypeCard(title: "Archivar regla",       subtitle: "Quitar una regla del grupo.",            icon: "trash",                              enabled: false, onTap: {})
                    voteTypeCard(title: "Remover miembro",      subtitle: "Sacar a alguien del grupo.",             icon: "person.fill.xmark",                  enabled: false, onTap: {})
                    voteTypeCard(title: "Retirar fondos",       subtitle: "Aprobar un retiro del fondo común.",     icon: "banknote",                           enabled: false, onTap: {})
                    voteTypeCard(title: "Asignar rol",          subtitle: "Promover a alguien a treasurer/etc.",    icon: "person.badge.shield.checkmark",      enabled: false, onTap: {})
                    voteTypeCard(title: "Disputa de slot",      subtitle: "Resolver disputa sobre un boleto/cupo.", icon: "ticket",                              enabled: false, onTap: {})
                }
                .padding(RuulSpacing.s5)
            }
            .scrollIndicators(.hidden)
            .background(Color.ruulBackgroundCanvas)
            .navigationTitle("Nueva votación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private func voteTypeCard(title: String, subtitle: String, icon: String, enabled: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(enabled ? Color.ruulAccentPrimary : Color.ruulTextTertiary)
                    .frame(width: 44, height: 44)
                    .background(Color.ruulBackgroundElevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(enabled ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            .padding(RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
            .opacity(enabled ? 1.0 : 0.6)
        }
        .buttonStyle(.ruulPress)
        .disabled(!enabled)
    }
}
