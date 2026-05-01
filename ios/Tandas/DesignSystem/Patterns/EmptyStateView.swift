import SwiftUI

/// Empty state — used when a list has no items, a search returns nothing, etc.
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String?
    private let primaryAction: (label: String, perform: () -> Void)?

    public init(
        systemImage: String,
        title: String,
        message: String? = nil,
        primaryAction: (label: String, perform: () -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.s5) {
            RuulIconBadge(systemImage, tint: .ruulAccentPrimary, size: .large)
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
            if let primaryAction {
                RuulButton(primaryAction.label, style: .primary, size: .medium, action: primaryAction.perform)
            }
        }
        .padding(RuulSpacing.s7)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("EmptyStateView") {
    VStack(spacing: RuulSpacing.s7) {
        EmptyStateView(
            systemImage: "person.2",
            title: "Aún no hay miembros",
            message: "Comparte el código del grupo para invitar amigos."
        )
        Divider()
        EmptyStateView(
            systemImage: "calendar",
            title: "Sin eventos esta semana",
            message: "Crea uno o espera a que alguien proponga.",
            primaryAction: ("Crear evento", { })
        )
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
