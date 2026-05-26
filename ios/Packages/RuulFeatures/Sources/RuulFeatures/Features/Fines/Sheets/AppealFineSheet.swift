import SwiftUI
import RuulUI
import RuulCore

/// Modal where a fined member writes their appeal reason. Submit triggers
/// `start_appeal` RPC server-side, which seeds eligible voters and emits
/// `appealCreated`. The 72h voting window starts from this submit.
public struct AppealFineSheet: View {
    @Binding var isPresented: Bool
    public let fine: Fine
    /// FASE 3 Action Warmth (B.2): async + Bool contract so we can
    /// respirar el éxito antes del dismiss.
    public let onSubmit: (String) async -> Bool

    public init(isPresented: Binding<Bool>, fine: Fine, onSubmit: @escaping (String) async -> Bool) {
        self._isPresented = isPresented
        self.fine = fine
        self.onSubmit = onSubmit
    }

    @State private var reason: String = ""
    @State private var isSubmitting = false
    @State private var successPhrase: String?
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
                .disabled(isSubmitting || successPhrase != nil)
                if let successPhrase {
                    HStack(spacing: RuulSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.ruulSemanticSuccess)
                            .accessibilityHidden(true)
                        Text(successPhrase)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ruulCardSurface(.solid, radius: RuulRadius.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                RuulButton(
                    confirmButtonLabel,
                    style: .primary,
                    size: .large,
                    isLoading: isSubmitting,
                    fillsWidth: true
                ) {
                    RuulHaptic.light.trigger()
                    Task { await submit() }
                }
                .disabled(trimmedReason.count < 10 || isSubmitting || successPhrase != nil)
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
        }
        .onAppear { reasonFocused = true }
        .sensoryFeedback(.success, trigger: successPhrase)
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
    }

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Enviando…" }
        return "Enviar apelación"
    }

    @MainActor
    private func submit() async {
        let r = trimmedReason
        guard r.count >= 10 else { return }
        isSubmitting = true
        let ok = await onSubmit(r)
        if ok {
            isSubmitting = false
            successPhrase = "Apelaste — el grupo tiene 72h para votar"
            try? await Task.sleep(for: .milliseconds(700))
            isPresented = false
        } else {
            isSubmitting = false
            RuulHaptic.error.trigger()
        }
    }
}
