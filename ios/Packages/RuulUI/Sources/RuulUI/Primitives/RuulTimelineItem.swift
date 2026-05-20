import SwiftUI

/// Single row of a vertical timeline. Renders an icon-bearing dot anchored
/// to a continuous rail (the rail is drawn by the row itself based on
/// `isFirst` / `isLast`), plus a content column with timestamp, title and
/// optional subtitle.
///
/// Used by `HistoryTimelineView` to surface group activity:
///   - "Cerraste la cena del jueves"
///   - "María apeló su multa de $300"
///   - "Se oficializaron 3 multas"
///   - "Juan se unió al grupo"
///
/// Composes vertically in a `VStack(spacing: 0)` so consecutive items
/// share the rail without visual gaps.
public struct RuulTimelineItem: View {
    public enum Tone: Sendable, Hashable {
        case neutral, positive, warning, negative, info

        var dotColor: Color {
            switch self {
            case .neutral:  return Color(.tertiaryLabel)
            case .positive: return .green
            case .warning:  return .orange
            case .negative: return .red
            case .info:     return .blue
            }
        }
    }

    private let icon: String
    private let title: String
    private let subtitle: String?
    private let timestamp: String
    private let tone: Tone
    private let isFirst: Bool
    private let isLast: Bool
    /// Opcional: cuando set, el dot icon se reemplaza por un avatar
    /// del actor (28pt) con tone dot como accent. Surfacea "quién"
    /// además de "qué" pasó en la timeline — útil cuando el title ya
    /// dice "Jose hizo X" y el avatar refuerza visualmente la lectura.
    private let actorName: String?
    private let actorAvatarURL: URL?

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        timestamp: String,
        tone: Tone = .neutral,
        isFirst: Bool = false,
        isLast: Bool = false,
        actorName: String? = nil,
        actorAvatarURL: URL? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.tone = tone
        self.isFirst = isFirst
        self.isLast = isLast
        self.actorName = actorName
        self.actorAvatarURL = actorAvatarURL
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            railColumn
            contentColumn
                .padding(.bottom, isLast ? 0 : RuulSpacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Vertical rail with the icon dot in the middle. The dot is rendered
    /// at a fixed inset from the top so successive items align cleanly.
    private var railColumn: some View {
        ZStack(alignment: .top) {
            // Rail line — drawn full height when not first/last, half height
            // for endpoints. Hidden when the row is both first AND last.
            if !(isFirst && isLast) {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)
                    .padding(.top, isFirst ? 24 : 0)
                    .padding(.bottom, isLast ? 0 : 0)
                    .frame(maxHeight: isLast ? 24 : .infinity, alignment: .top)
            }
            ZStack {
                if let actorName {
                    // Avatar mode — el actor es conocido. La tone dot
                    // queda como accent encima a la derecha (badge style
                    // tipo Slack/Apple Messages).
                    RuulAvatar(name: actorName, imageURL: actorAvatarURL, size: .medium)
                        .frame(width: 28, height: 28)
                } else {
                    // Icon mode — fallback para events sin actor (rsvp
                    // deadline, hours-before-event reminders sintéticos).
                    Circle()
                        .fill(Color.ruulBackgroundRecessed)
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.primary)
                }
                Circle()
                    .fill(tone.dotColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 10, y: -10)
            }
            .padding(.top, 4)
        }
        .frame(width: 28)
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timestamp)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var accessibilityLabel: String {
        var parts = [timestamp, title]
        if let subtitle { parts.append(subtitle) }
        return parts.joined(separator: ". ")
    }
}

#if DEBUG
#Preview("RuulTimelineItem") {
    ScrollView {
        VStack(spacing: 0) {
            RuulTimelineItem(
                icon: "checkmark",
                title: "Cerraste la cena del jueves",
                subtitle: "12 confirmados, 9 llegaron, 3 multas propuestas",
                timestamp: "HOY · 22:14",
                tone: .positive,
                isFirst: true
            )
            RuulTimelineItem(
                icon: "hand.raised.fill",
                title: "María apeló su multa de $300",
                subtitle: "Llegada tardía · Cena del 12 de mayo",
                timestamp: "HOY · 19:02",
                tone: .warning
            )
            RuulTimelineItem(
                icon: "exclamationmark.triangle.fill",
                title: "Se oficializaron 3 multas",
                subtitle: "Total: $700",
                timestamp: "AYER · 23:30",
                tone: .negative
            )
            RuulTimelineItem(
                icon: "person.fill.badge.plus",
                title: "Juan se unió al grupo",
                timestamp: "LUN · 10:12",
                tone: .info
            )
            RuulTimelineItem(
                icon: "calendar.badge.plus",
                title: "Creaste la cena recurrente del jueves",
                timestamp: "DOM · 14:00",
                tone: .neutral,
                isLast: true
            )
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
