import SwiftUI
import RuulUI
import RuulCore

public struct CancelEventSheet: View {
    @Binding var isPresented: Bool
    @State private var reason: String = ""
    public var onConfirm: (String?) -> Void

    public init(isPresented: Binding<Bool>, onConfirm: @escaping (String?) -> Void) {
        self._isPresented = isPresented
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Cancelar evento",
            dismissAction: { isPresented = false },
            primaryCTA: ("Cancelar evento", {
                onConfirm(reason.isEmpty ? nil : reason)
                isPresented = false
            })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
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
