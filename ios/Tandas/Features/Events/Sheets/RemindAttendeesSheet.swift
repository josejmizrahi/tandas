import SwiftUI

struct RemindAttendeesSheet: View {
    @Binding var isPresented: Bool
    let pendingCount: Int
    let eventTitle: String
    let vocabulary: String
    var onSend: () -> Void

    var body: some View {
        ModalSheetTemplate(
            title: "Mandar recordatorio",
            dismissAction: { isPresented = false },
            primaryCTA: ("Enviar a \(pendingCount) personas", {
                onSend()
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Mensaje preview")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("¿Confirmas? Falta tu RSVP para \"\(eventTitle)\"")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                Text("Esto avisa a las \(pendingCount) personas que aún no han respondido.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
