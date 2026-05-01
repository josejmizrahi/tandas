import SwiftUI

/// Large glass card with icon + title + description + tap action.
/// Used for "pick one of N options" patterns in onboarding (invite methods,
/// destination after onboarding, etc.).
public struct RuulActionableCard: View {
    private let icon: String
    private let title: String
    private let subtitle: String?
    private let tint: Color
    private let trailingAccessory: AccessoryStyle
    private let action: () -> Void

    public enum AccessoryStyle: Sendable, Hashable {
        case chevron
        case none
        case badge(String)        // small text badge on the right
    }

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tint: Color = .ruulAccentPrimary,
        accessory: AccessoryStyle = .chevron,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.trailingAccessory = accessory
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.s4) {
                RuulIconBadge(icon, tint: tint, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                accessoryView
            }
            .padding(RuulSpacing.s4)
            .background(
                Color.ruulBackgroundElevated,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch trailingAccessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
        case .none:
            EmptyView()
        case .badge(let text):
            Text(text)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.horizontal, RuulSpacing.s2)
                .padding(.vertical, 2)
                .background(Color.ruulBackgroundRecessed, in: Capsule())
        }
    }
}

#if DEBUG
#Preview("RuulActionableCard") {
    VStack(spacing: RuulSpacing.s3) {
        RuulActionableCard(
            icon: "link",
            title: "Compartir link",
            subtitle: "Mándalo por WhatsApp, SMS, donde sea."
        ) { }
        RuulActionableCard(
            icon: "person.crop.circle.badge.plus",
            title: "Agregar por número",
            subtitle: "Importa de contactos o escríbelo a mano.",
            accessory: .badge("Recomendado")
        ) { }
        RuulActionableCard(
            icon: "forward.fill",
            title: "Saltar",
            subtitle: "Invitas después.",
            tint: .ruulTextSecondary,
            accessory: .none
        ) { }
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
