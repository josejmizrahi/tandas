import SwiftUI
import RuulUI
import RuulCore

public struct CancelAttendanceSheet: View {
    @Binding var isPresented: Bool
    @State private var reason: String = ""
    public let isAfterDeadline: Bool
    public var onConfirm: (String?) -> Void

    public init(isPresented: Binding<Bool>, isAfterDeadline: Bool, onConfirm: @escaping (String?) -> Void) {
        self._isPresented = isPresented
        self.isAfterDeadline = isAfterDeadline
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "No voy a poder ir",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cambiar mi RSVP a no voy", {
                onConfirm(reason.isEmpty ? nil : reason)
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                if isAfterDeadline {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text("Esto puede generar multa según las reglas del grupo.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(RuulSpacing.sm)
                    .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                }
                RuulTextField("¿Por qué no puedes?", text: $reason, label: "Razón (opcional)")
            }
        }
    }
}
