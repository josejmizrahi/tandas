import SwiftUI
import RuulUI
import RuulCore

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
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                if isAfterDeadline {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.ruulWarning)
                        Text("Esto puede generar multa según las reglas del grupo.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    .padding(RuulSpacing.sm)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .stroke(Color.ruulSeparator, lineWidth: 0.5)
                    )
                }
                RuulTextField("¿Por qué no puedes?", text: $reason, label: "Razón (opcional)")
            }
        }
    }
}
