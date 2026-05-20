import SwiftUI
import RuulUI
import RuulCore

public struct RemindAttendeesSheet: View {
    @Binding var isPresented: Bool
    public let pendingCount: Int
    public let eventTitle: String
    public let vocabulary: String
    public var onSend: () -> Void

    public init(isPresented: Binding<Bool>, pendingCount: Int, eventTitle: String, vocabulary: String, onSend: @escaping () -> Void) {
        self._isPresented = isPresented
        self.pendingCount = pendingCount
        self.eventTitle = eventTitle
        self.vocabulary = vocabulary
        self.onSend = onSend
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Mandar recordatorio",
            dismissAction: { isPresented = false },
            primaryCTA: ("Enviar a \(pendingCount) personas", {
                onSend()
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Mensaje preview")
                    .font(.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("¿Confirmas? Falta tu RSVP para \"\(eventTitle)\"")
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                Text("Esto avisa a las \(pendingCount) personas que aún no han respondido.")
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
