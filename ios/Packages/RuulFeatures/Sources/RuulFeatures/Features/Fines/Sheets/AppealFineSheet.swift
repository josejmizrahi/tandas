import SwiftUI
import RuulUI
import RuulCore

/// Modal where a fined member writes their appeal reason. Submit triggers
/// `start_appeal` RPC server-side, which seeds eligible voters and emits
/// `appealCreated`. The 72h voting window starts from this submit.
public struct AppealFineSheet: View {
    @Binding var isPresented: Bool
    public let fine: Fine
    public let onSubmit: (String) -> Void

    public init(isPresented: Binding<Bool>, fine: Fine, onSubmit: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.fine = fine
        self.onSubmit = onSubmit
    }

    @State private var reason: String = ""
    @FocusState private var reasonFocused: Bool

    public var body: some View {
        ModalSheetTemplate(
            title: "Apelar multa",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Text("Cuéntale al grupo por qué crees que esta multa no aplica. Tendrán 72 horas para votar.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text(fine.reason)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                Spacer()
                RuulMoneyView(
                    amount: fine.amount,
                    currency: "MXN",
                    size: .large,
                    color: .negative
                )
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
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
