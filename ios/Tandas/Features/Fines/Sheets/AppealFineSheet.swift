import SwiftUI

/// Modal where a fined member writes their appeal reason. Submit triggers
/// `start_appeal` RPC server-side, which seeds eligible voters and emits
/// `appealCreated`. The 72h voting window starts from this submit.
struct AppealFineSheet: View {
    @Binding var isPresented: Bool
    let fine: Fine
    let onSubmit: (String) -> Void

    @State private var reason: String = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        ModalSheetTemplate(
            title: "Apelar multa",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                Text("Cuéntale al grupo por qué crees que esta multa no aplica. Tendrán 72 horas para votar.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                summaryCard
                RuulTextField(
                    "Tu argumento (mínimo 10 caracteres)",
                    text: $reason,
                    label: "Argumento"
                )
                .focused($reasonFocused)
                RuulButton(
                    "Enviar apelación",
                    style: .primary,
                    size: .large,
                    fillsWidth: true,
                    action: submit
                )
                .disabled(trimmedReason.count < 10)
            }
        }
        .onAppear { reasonFocused = true }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack {
                Text(fine.reason)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
                Text(fine.amountFormatted)
                    .ruulTextStyle(RuulTypography.statMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
        .padding(RuulSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let r = trimmedReason
        guard r.count >= 10 else { return }
        onSubmit(r)
        isPresented = false
    }
}
