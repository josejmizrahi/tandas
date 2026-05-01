import SwiftUI

struct CancelAttendanceSheet: View {
    @Binding var isPresented: Bool
    @State private var reason: String = ""
    let isAfterDeadline: Bool
    var onConfirm: (String?) -> Void

    var body: some View {
        ModalSheetTemplate(
            title: "No voy a poder ir",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cambiar mi RSVP a no voy", {
                onConfirm(reason.isEmpty ? nil : reason)
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                if isAfterDeadline {
                    HStack(spacing: RuulSpacing.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.ruulSemanticWarning)
                        Text("Esto puede generar multa según las reglas del grupo.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    .padding(RuulSpacing.s3)
                    .background(Color.ruulSemanticWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
                RuulTextField("¿Por qué no puedes?", text: $reason, label: "Razón (opcional)")
            }
        }
    }
}
