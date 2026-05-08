import SwiftUI
import RuulUI
import RuulCore

public struct CloseEventSheet: View {
    @Binding var isPresented: Bool
    public let vocabulary: String
    public var onConfirm: () -> Void

    public init(isPresented: Binding<Bool>, vocabulary: String, onConfirm: @escaping () -> Void) {
        self._isPresented = isPresented
        self.vocabulary = vocabulary
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Cerrar \(vocabulary)",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cerrar", {
                onConfirm()
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
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
