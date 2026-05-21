import SwiftUI
import RuulUI
import RuulCore

/// Full-tile event card. Apple Sports pattern: the cover IS the card —
/// content is overlaid in white over a vignette gradient. No body section,
/// no white space. Each card has its own color identity from the cover.
public struct EventCard: View {
    public let event: Event
    public let myStatus: RSVPStatus?
    public let isHostedByMe: Bool
    public let attendeeAvatars: [RuulAvatarStack.Person]
    public let confirmedCount: Int
    public let isAtCapacity: Bool
    public let onTap: () -> Void

    public init(
        event: Event,
        myStatus: RSVPStatus?,
        isHostedByMe: Bool,
        attendeeAvatars: [RuulAvatarStack.Person] = [],
        confirmedCount: Int = 0,
        isAtCapacity: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.event = event
        self.myStatus = myStatus
        self.isHostedByMe = isHostedByMe
        self.attendeeAvatars = attendeeAvatars
        self.confirmedCount = confirmedCount
        self.isAtCapacity = isAtCapacity
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                cover
                    .aspectRatio(16/11, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                // Vignette: bottom 60% darkens for white-text legibility,
                // top stays clean so status badges read against the cover hue.
                LinearGradient(
                    stops: [
                        .init(color: .clear,                    location: 0.00),
                        .init(color: .clear,                    location: 0.30),
                        .init(color: Color.black.opacity(0.20), location: 0.55),
                        .init(color: Color.black.opacity(0.78), location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                topBadgesOverlay
                bottomContentOverlay
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cover

    @ViewBuilder
    private var cover: some View {
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

    private var fallbackCover: some View {
        let cover = RuulCoverCatalog.cover(named: event.coverImageName)
        return RuulCoverView(cover)
    }

    // MARK: - Top badges (status indicators, always visible against cover)

    private var topBadgesOverlay: some View {
        VStack(alignment: .leading) {
            HStack(spacing: RuulSpacing.xs) {
                if event.status == .inProgress {
                    livePill
                }
                if event.status == .cancelled {
                    overlayBadge(icon: "xmark", text: "Cancelado", tint: Color.red)
                }
                if event.status == .closed {
                    overlayBadge(icon: "checkmark", text: "Cerrado", tint: Color.black.opacity(0.55))
                }
                if isAtCapacity && event.status == .upcoming {
                    overlayBadge(icon: "person.fill.checkmark", text: "Lleno", tint: Color.red)
                }
                Spacer()
                if isHostedByMe {
                    overlayBadge(icon: "star.fill", text: "Hosteas", tint: Color.black.opacity(0.55))
                }
            }
            .padding(RuulSpacing.sm)
            Spacer()
        }
    }

    // MARK: - Bottom content (date / title / meta / footer all in white)

    private var bottomContentOverlay: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateDescription)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85))

                Text(event.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
            }

            HStack(spacing: RuulSpacing.sm) {
                if let location = event.locationName, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if confirmedCount > 0 {
                    Text("\(confirmedCount) van")
                        .font(.footnote.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.white)
                }
                if let myStatus, myStatus != .pending {
                    myRSVPPill(myStatus)
                }
            }
        }
        .padding(RuulSpacing.md)
    }

    // MARK: - Helpers

    private var dateDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt) {
            return "Hoy · \(event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(event.startsAt) {
            return "Mañana · \(event.startsAt.ruulShortTime)"
        }
        return "\(event.startsAt.ruulShortDate) · \(event.startsAt.ruulShortTime)"
    }

    private func overlayBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, RuulSpacing.xxs + 1)
        .background(tint, in: Capsule())
    }

    private var livePill: some View {
        HStack(spacing: RuulSpacing.xxs + 1) {
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
            Text("En vivo")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, RuulSpacing.xxs + 1)
        .background(Color.red, in: Capsule())
    }

    private func myRSVPPill(_ status: RSVPStatus) -> some View {
        let (icon, label): (String, String) = {
            switch status {
            case .going:      return ("checkmark", "Vas")
            case .maybe:      return ("questionmark", "Tal vez")
            case .declined:   return ("xmark", "No vas")
            case .waitlisted: return ("person.crop.circle.badge.clock", "Lista")
            case .pending:    return ("circle", "")
            }
        }()
        return HStack(spacing: RuulSpacing.xxs) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(label)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, RuulSpacing.xs)
        .padding(.vertical, RuulSpacing.xxs)
        .background(Color.white.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 0.5))
    }
}
