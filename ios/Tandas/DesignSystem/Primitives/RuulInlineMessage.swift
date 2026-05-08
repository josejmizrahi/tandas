import SwiftUI
import RuulUI

/// Mensaje contextual inline. Per DS doc §3.14.
public struct RuulInlineMessage: View {
    public enum Style: Sendable, Hashable {
        case info, success, warning, error

        var background: Color {
            switch self {
            case .info:    return .ruulInfoBackground
            case .success: return .ruulPositiveBackground
            case .warning: return .ruulWarningBackground
            case .error:   return .ruulNegativeBackground
            }
        }

        var foreground: Color {
            switch self {
            case .info:    return .ruulInfo
            case .success: return .ruulPositive
            case .warning: return .ruulWarning
            case .error:   return .ruulNegative
            }
        }

        var defaultIcon: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            }
        }
    }

    public struct ActionConfig {
        public let label: String
        public let handler: () -> Void
        public init(label: String, handler: @escaping () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    private let text: String
    private let style: Style
    private let icon: String?
    private let action: ActionConfig?

    public init(
        _ text: String,
        style: Style = .info,
        icon: String? = nil,
        action: ActionConfig? = nil
    ) {
        self.text = text
        self.style = style
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: icon ?? style.defaultIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(style.foreground)

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.ruulCaption)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let action {
                    Button(action.label, action: action.handler)
                        .font(.ruulCaptionEmphasis)
                        .foregroundStyle(style.foreground)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium))
    }
}

#if DEBUG
#Preview("RuulInlineMessage") {
    VStack(spacing: RuulSpacing.md) {
        RuulInlineMessage("Tu RSVP se actualizó correctamente.", style: .success)
        RuulInlineMessage("Cierra en 2 horas.", style: .warning, action: .init(label: "Ver", handler: {}))
        RuulInlineMessage("No pudimos cargar la información.", style: .error)
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
