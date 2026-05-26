import SwiftUI
import RuulUI
import RuulCore

public struct CloseEventSheet: View {
    @Binding var isPresented: Bool
    public let vocabulary: String
    public let eventName: String
    /// FASE 3 Action Warmth (B.2): contract async → Bool so we can
    /// respirar la consecuencia + atribuir al humano antes del dismiss.
    /// `true` = el cierre fue exitoso; `false` = error, mantener sheet.
    public var onConfirm: () async -> Bool

    @State private var isSubmitting = false
    @State private var successPhrase: String?

    public init(
        isPresented: Binding<Bool>,
        vocabulary: String,
        eventName: String,
        onConfirm: @escaping () async -> Bool
    ) {
        self._isPresented = isPresented
        self.vocabulary = vocabulary
        self.eventName = eventName
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Cerrar \(vocabulary)",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Después de cerrar, no se podrán hacer más check-ins.")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                if vocabulary != "evento" {
                    Text("Si tu grupo tiene generación automática, creamos el siguiente \(vocabulary).")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
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
                .disabled(isSubmitting || successPhrase != nil)
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
        }
        .sensoryFeedback(.success, trigger: successPhrase)
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Cerrando…" }
        return "Cerrar"
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        let ok = await onConfirm()
        if ok {
            isSubmitting = false
            successPhrase = "Cerraste \(eventName)"
            try? await Task.sleep(for: .milliseconds(700))
            isPresented = false
        } else {
            isSubmitting = false
            RuulHaptic.error.trigger()
        }
    }
}
