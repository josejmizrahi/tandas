import SwiftUI

struct CloseEventSheet: View {
    @Binding var isPresented: Bool
    let vocabulary: String
    var onConfirm: () -> Void

    var body: some View {
        ModalSheetTemplate(
            title: "Cerrar \(vocabulary)",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cerrar", {
                onConfirm()
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Después de cerrar, no se podrán hacer más check-ins.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if vocabulary != "evento" {
                    Text("Si tu grupo tiene generación automática, creamos el siguiente \(vocabulary).")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
    }
}
