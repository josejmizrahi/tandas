import SwiftUI
import RuulUI

/// Inbox row primitive. Renders a single pending user-action (multa por
/// pagar, apelación por votar, RSVP por contestar, multas por revisar al
/// host) as a tappable monochrome card with:
///   - circle icon on the lead (categoriza el tipo de acción)
///   - title + subtitle + optional metadata row
///   - priority dot (8pt colored circle, never a tinted background)
///   - optional time-remaining tag in monospace
///   - chevron on the trail
///
/// Intentionally generic: the inbox view maps any `UserAction` (futuro
/// modelo de plataforma) onto these props. Keeps the DS unaware of the
/// platform/template layer.
public struct ActionCard: View {
    public enum Priority: Sendable, Hashable {
        case low, medium, high, urgent

        var dotColor: Color {
            switch self {
            case .low:    return .ruulTextTertiary
            case .medium: return .ruulInfo
            case .high:   return .ruulWarning
            case .urgent: return .ruulNegative
            }
        }

        var label: String {
            switch self {
            case .low:    return "BAJA"
            case .medium: return "MEDIA"
            case .high:   return "ALTA"
            case .urgent: return "URGENTE"
            }
        }
    }

    private let icon: String
    private let meta: String?              // uppercase tracked label above title
    private let title: String
    private let subtitle: String?
    private let priority: Priority
    private let timeRemaining: String?
    private let onTap: () -> Void

    public init(
        icon: String,
        meta: String? = nil,
        title: String,
        subtitle: String? = nil,
        priority: Priority = .medium,
        timeRemaining: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.icon = icon
        self.meta = meta
        self.title = title
        self.subtitle = subtitle
        self.priority = priority
        self.timeRemaining = timeRemaining
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.sm) {
                iconBadge
                contentColumn
                Spacer(minLength: 0)
                trailingColumn
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity)
            .background(Color.ruulSurface, in: shape)
            .overlay(shape.stroke(Color.ruulSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(Color.ruulBackground)
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(Color.ruulSeparator, lineWidth: 0.5))
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let meta {
                Text(meta.uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextAccent)
                    .lineLimit(1)
            }
            HStack(spacing: RuulSpacing.xs) {
                Circle()
                    .fill(priority.dotColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: RuulSpacing.xxs) {
            if let timeRemaining {
                Text(timeRemaining)
                    .ruulTextStyle(RuulTypography.statSmall)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let meta { parts.append(meta) }
        parts.append(title)
        if let subtitle { parts.append(subtitle) }
        parts.append("Prioridad \(priority.label.lowercased())")
        if let timeRemaining { parts.append(timeRemaining) }
        return parts.joined(separator: ". ")
    }
}

#if DEBUG
#Preview("ActionCard") {
    ScrollView {
        VStack(spacing: RuulSpacing.sm) {
            ActionCard(
                icon: "exclamationmark.triangle.fill",
                title: "Multa pendiente: $300",
                subtitle: "No-show en cena del 12 de mayo",
                priority: .urgent,
                timeRemaining: "VENCE EN 3 D",
                onTap: {}
            )
            ActionCard(
                icon: "hand.raised.fill",
                title: "Vota una apelación",
                subtitle: "María apeló su multa por llegada tardía",
                priority: .high,
                timeRemaining: "12 H",
                onTap: {}
            )
            ActionCard(
                icon: "checkmark.circle.fill",
                title: "Confirma tu asistencia",
                subtitle: "Cena del jueves en casa de Juan",
                priority: .medium,
                onTap: {}
            )
            ActionCard(
                icon: "doc.text.magnifyingglass",
                title: "Revisa multas propuestas",
                subtitle: "3 multas esperan tu revisión antes de oficializarse",
                priority: .high,
                timeRemaining: "EN 18 H",
                onTap: {}
            )
            ActionCard(
                icon: "bell.fill",
                title: "Recordatorio de pago",
                subtitle: "Tienes 2 multas con más de una semana",
                priority: .low,
                onTap: {}
            )
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
