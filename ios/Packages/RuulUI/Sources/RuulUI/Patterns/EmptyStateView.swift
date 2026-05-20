import SwiftUI

/// Empty state — used when a list has no items, a search returns nothing, etc.
///
/// `secondaryAction` is rendered as a `.glass` button below the primary one.
/// Use it sparingly: the cross-app empty-states with two equally-weighted
/// CTAs are rare (e.g. "no groups yet" → Crear / Unirme). Most empties
/// have at most one CTA.
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String?
    private let primaryAction: (label: String, perform: () -> Void)?
    private let secondaryAction: (label: String, perform: () -> Void)?

    public init(
        systemImage: String,
        title: String,
        message: String? = nil,
        primaryAction: (label: String, perform: () -> Void)? = nil,
        secondaryAction: (label: String, perform: () -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.lg) {
            RuulIconBadge(systemImage, tint: .ruulAccent, size: .large)
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
            if primaryAction != nil || secondaryAction != nil {
                VStack(spacing: RuulSpacing.sm) {
                    if let primaryAction {
                        RuulButton(primaryAction.label, style: .primary, size: .medium, action: primaryAction.perform)
                    }
                    if let secondaryAction {
                        RuulButton(secondaryAction.label, style: .glass, size: .medium, action: secondaryAction.perform)
                    }
                }
            }
        }
        .padding(RuulSpacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("EmptyStateView") {
    VStack(spacing: RuulSpacing.xxl) {
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
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
