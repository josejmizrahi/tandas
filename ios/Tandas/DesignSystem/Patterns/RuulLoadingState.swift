import SwiftUI

/// Loading state simple — ProgressView + mensaje opcional.
/// Per DS doc §3.13. **Reemplaza el shimmer LoadingStateView** (anti-pattern §13).
public struct RuulLoadingState: View {
    private let message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.ruulAccent)
            if let message {
                Text(message)
                    .font(.ruulCaption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("RuulLoadingState") {
    VStack(spacing: RuulSpacing.xxl) {
        RuulLoadingState()
        RuulLoadingState(message: "Cargando reglas del grupo…")
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
