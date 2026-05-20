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
        VStack(spacing: RuulSpacing.lg) {
            RuulIconBadge(systemImage, tint: .ruulNegative, size: .large)
            VStack(spacing: RuulSpacing.xs) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let retryAction {
                RuulButton(retryAction.label, systemImage: "arrow.clockwise", style: .secondary, size: .medium, action: retryAction.perform)
            }
        }
        .padding(RuulSpacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("ErrorStateView") {
    VStack(spacing: RuulSpacing.xxl) {
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
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
