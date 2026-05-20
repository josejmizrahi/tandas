import SwiftUI

/// Mensaje contextual inline. Per DS doc §3.14.
public struct RuulInlineMessage: View {
    public enum Style: Sendable, Hashable {
        case info, success, warning, error

        var background: Color {
            switch self {
            case .info:    return .blue.opacity(0.15)
            case .success: return .green.opacity(0.15)
            case .warning: return .orange.opacity(0.15)
            case .error:   return .red.opacity(0.15)
            }
        }

        var foreground: Color {
            switch self {
            case .info:    return .blue
            case .success: return .green
            case .warning: return .orange
            case .error:   return .red
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
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                if let action {
                    Button(action.label, action: action.handler)
                        .font(.subheadline.weight(.medium))
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
