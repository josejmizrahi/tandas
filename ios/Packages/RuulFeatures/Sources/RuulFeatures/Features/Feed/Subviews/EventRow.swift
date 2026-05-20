import SwiftUI
import RuulUI
import RuulCore

/// Compact list row for events. The workhorse cell across MyFeedView,
/// PastResourcesView, and any future "list of events" surface.
///
/// Visual model (Apple Invites compact pattern):
///
///   ┌──────┐  GROUP NAME · HOY 9:00 PM
///   │ cover│  Cena del jueves
///   │ 64×64│  📍 Casa de María · 4 van
///   └──────┘
///
/// - Left: 64×64 cover thumbnail (image or procedural mesh fallback) with
///   the rounded-square Apple Invites look.
/// - Right: tracked uppercase metadata + display title + secondary meta row.
/// - Whole cell is `.ruulPress` so tap haptic + scale feedback come for free.
public struct EventRow: View {
    public let event: Event
    /// Origin group for cross-grupos surfaces (Home multi-group, MyFeed).
    /// When non-nil, an inline `RuulOriginTag` (avatar + group name) renders
    /// above the title so the row carries its group identity. Per DS v3
    /// §3.12 / §4.5.
    public let originGroup: RuulCore.Group?
    /// Legacy plain-text group label. Deprecated — prefer `originGroup` so
    /// the row gets the full DS v3 origin tag (avatar + name + tracking).
    /// Honored only when `originGroup` is nil so callers can migrate
    /// incrementally without losing context.
    public let groupName: String?
    public let myStatus: RSVPStatus?
    public let onTap: () -> Void

    public init(
        event: Event,
        originGroup: RuulCore.Group? = nil,
        groupName: String? = nil,
        myStatus: RSVPStatus?,
        onTap: @escaping () -> Void
    ) {
        self.event = event
        self.originGroup = originGroup
        self.groupName = groupName
        self.myStatus = myStatus
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                cover
                content
                Spacer(minLength: 0)
                trailing
            }
            .padding(.vertical, RuulSpacing.sm)
            .padding(.horizontal, RuulSpacing.md)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Cover thumbnail

    @ViewBuilder
    private var cover: some View {
        SwiftUI.Group {
            if let url = event.coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:                fallbackCover
                    }
                }
            } else {
                fallbackCover
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var fallbackCover: some View {
        let cover = RuulCoverCatalog.cover(named: event.coverImageName)
        return RuulCoverView(cover)
    }

    // MARK: - Content column

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let originGroup {
                RuulOriginTag(group: originGroup)
            }
            Text(metaLine)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(metaColor)
                .lineLimit(1)
            Text(event.title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let location = event.locationName, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.caption2.weight(.semibold))
                    Text(location)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.secondary)
            }
        }
    }

    /// Meta line composes group name (if cross-group, legacy path) + date
    /// language. When `originGroup` is set, the dedicated `RuulOriginTag`
    /// already carries identity, so we drop the textual prefix to avoid
    /// duplication. "LOS CUATES · HOY 9:00 PM" or "MAÑANA 9:00 PM".
    private var metaLine: String {
        var parts: [String] = []
        if originGroup == nil, let groupName, !groupName.isEmpty {
            parts.append(groupName.uppercased())
        }
        parts.append(dateLabel.uppercased())
        return parts.joined(separator: " · ")
    }

    private var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt)    { return "Hoy \(event.startsAt.ruulShortTime)" }
        if calendar.isDateInTomorrow(event.startsAt) { return "Mañana \(event.startsAt.ruulShortTime)" }
        if calendar.isDateInYesterday(event.startsAt) { return "Ayer" }
        return "\(event.startsAt.ruulShortDate) \(event.startsAt.ruulShortTime)"
    }

    /// Meta color carries status: cancelled is red, hosted-by-me + future is
    /// accent, in-progress is the live red, otherwise secondary.
    private var metaColor: Color {
        if event.status == .cancelled { return .red }
        if event.status == .inProgress { return .red }
        if event.startsAt < .now && event.status == .upcoming { return Color(.tertiaryLabel) }
        if Calendar.current.isDateInToday(event.startsAt) { return .ruulAccent }
        return .secondary
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        if event.status == .inProgress {
            livePill
        } else if let myStatus, myStatus != .pending {
            rsvpPill(myStatus)
        }
    }

    private var livePill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("EN VIVO")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.red)
        }
    }

    private func rsvpPill(_ status: RSVPStatus) -> some View {
        let (icon, label, color): (String, String, Color) = {
            switch status {
            case .going:      return ("checkmark", "Vas",       .green)
            case .maybe:      return ("questionmark", "Tal vez", .orange)
            case .declined:   return ("xmark", "No vas",         Color(.tertiaryLabel))
            case .waitlisted: return ("hourglass", "Lista",      .ruulAccent)
            case .pending:    return ("circle", "",              Color(.tertiaryLabel))
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(color)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let originGroup { parts.append(originGroup.name) }
        else if let groupName { parts.append(groupName) }
        parts.append(event.title)
        parts.append(event.startsAt.ruulRelativeDescription)
        if event.status == .cancelled { parts.append("cancelado") }
        if event.status == .inProgress { parts.append("en curso") }
        if let myStatus, myStatus != .pending {
            parts.append(rsvpAccessibilityLabel(myStatus))
        }
        return parts.joined(separator: ", ")
    }

    private func rsvpAccessibilityLabel(_ status: RSVPStatus) -> String {
        switch status {
        case .going:      return "vas"
        case .maybe:      return "tal vez"
        case .declined:   return "no vas"
        case .waitlisted: return "lista de espera"
        case .pending:    return ""
        }
    }
}
