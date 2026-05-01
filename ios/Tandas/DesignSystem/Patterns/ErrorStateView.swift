import SwiftUI

/// Error state with retry CTA. Used for recoverable errors (network, etc.).
public struct ErrorStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String?
    private let retryAction: (label: String, perform: () -> Void)?

    public init(
        systemImage: String = "exclamationmark.triangle",
        title: String,
        message: String? = nil,
        retryAction: (label: String, perform: () -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.s5) {
            RuulIconBadge(systemImage, tint: .ruulSemanticError, size: .large)
            VStack(spacing: RuulSpacing.s2) {
                Text(title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let retryAction {
                RuulButton(retryAction.label, systemImage: "arrow.clockwise", style: .secondary, size: .medium, action: retryAction.perform)
            }
        }
        .padding(RuulSpacing.s7)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("ErrorStateView") {
    VStack(spacing: RuulSpacing.s7) {
        ErrorStateView(
            title: "No pudimos cargar tus grupos",
            message: "Verifica tu conexión y vuelve a intentar.",
            retryAction: ("Reintentar", { })
        )
        Divider()
        ErrorStateView(
            systemImage: "wifi.slash",
            title: "Sin conexión",
            message: "Reconecta para sincronizar."
        )
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
