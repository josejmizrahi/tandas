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
            case .neutral:  return .ruulTextTertiary
            case .positive: return .ruulSemanticSuccess
            case .warning:  return .ruulSemanticWarning
            case .negative: return .ruulSemanticError
            case .info:     return .ruulSemanticInfo
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

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        timestamp: String,
        tone: Tone = .neutral,
        isFirst: Bool = false,
        isLast: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.tone = tone
        self.isFirst = isFirst
        self.isLast = isLast
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            railColumn
            contentColumn
                .padding(.bottom, isLast ? 0 : RuulSpacing.s5)
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
                    .fill(Color.ruulBorderSubtle)
                    .frame(width: 1)
                    .padding(.top, isFirst ? 24 : 0)
                    .padding(.bottom, isLast ? 0 : 0)
                    .frame(maxHeight: isLast ? 24 : .infinity, alignment: .top)
            }
            ZStack {
                Circle()
                    .fill(Color.ruulBackgroundCanvas)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.ruulTextPrimary)
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
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(title)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
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
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
