import SwiftUI

struct CancelEventSheet: View {
    @Binding var isPresented: Bool
    @State private var reason: String = ""
    var onConfirm: (String?) -> Void

    var body: some View {
        ModalSheetTemplate(
            title: "Cancelar evento",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cancelar evento", {
                onConfirm(reason.isEmpty ? nil : reason)
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Esto avisa a todos los confirmados.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulTextField("Razón (opcional)", text: $reason, label: "¿Por qué?")
                RuulButton("No, mantenerlo", style: .glass, size: .medium, fillsWidth: true) {
                    isPresented = false
                }
            }
        }
    }
}
