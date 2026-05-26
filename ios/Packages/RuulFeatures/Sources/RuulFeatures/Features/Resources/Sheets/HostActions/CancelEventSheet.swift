import SwiftUI
import RuulUI
import RuulCore

public struct CancelEventSheet: View {
    @Binding var isPresented: Bool
    public let eventName: String
    /// FASE 3 Action Warmth (B.2): async + Bool contract so we can
    /// respirar la consecuencia antes del dismiss.
    public var onConfirm: (String?) async -> Bool

    @State private var reason: String = ""
    @State private var isSubmitting = false
    @State private var successPhrase: String?

    public init(
        isPresented: Binding<Bool>,
        eventName: String,
        onConfirm: @escaping (String?) async -> Bool
    ) {
        self._isPresented = isPresented
        self.eventName = eventName
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Cancelar evento",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Esto avisa a todos los confirmados.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                RuulTextField("Razón (opcional)", text: $reason, label: "¿Por qué?")
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
                    style: .destructive,
                    size: .large,
                    isLoading: isSubmitting,
                    fillsWidth: true
                ) {
                    RuulHaptic.light.trigger()
                    Task { await submit() }
                }
                .disabled(isSubmitting || successPhrase != nil)
                RuulButton("No, mantenerlo", style: .glass, size: .medium, fillsWidth: true) {
                    isPresented = false
                }
                .disabled(isSubmitting || successPhrase != nil)
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
        }
        .sensoryFeedback(.success, trigger: successPhrase)
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Cancelando…" }
        return "Cancelar evento"
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        let ok = await onConfirm(reason.isEmpty ? nil : reason)
        if ok {
            isSubmitting = false
            successPhrase = "Cancelaste \(eventName)"
            try? await Task.sleep(for: .milliseconds(700))
            isPresented = false
        } else {
            isSubmitting = false
            RuulHaptic.error.trigger()
        }
    }
}
