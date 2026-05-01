import SwiftUI

/// Magazine-style card representing a single event in lists. Full-width
/// 16:9 cover anchors the visual identity; meta + social proof live below.
/// Solid elevated card (not glass) — glass is reserved for transient
/// surfaces (nav bars, sheets, overlays).
struct EventCard: View {
    let event: Event
    let myStatus: RSVPStatus?
    let isHostedByMe: Bool
    let attendeeAvatars: [RuulAvatarStack.Person]
    let confirmedCount: Int
    let onTap: () -> Void

    init(
        event: Event,
        myStatus: RSVPStatus?,
        isHostedByMe: Bool,
        attendeeAvatars: [RuulAvatarStack.Person] = [],
        confirmedCount: Int = 0,
        onTap: @escaping () -> Void
    ) {
        self.event = event
        self.myStatus = myStatus
        self.isHostedByMe = isHostedByMe
        self.attendeeAvatars = attendeeAvatars
        self.confirmedCount = confirmedCount
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                coverHero
                content
            }
            .background(Color.ruulBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .ruulElevation(.md)
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Cover hero (16:9, edge-to-edge inside the card)

    private var coverHero: some View {
        ZStack(alignment: .topLeading) {
            cover
                .aspectRatio(16/9, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

            // Subtle top-left gradient for badge legibility against bright covers.
            LinearGradient(
                colors: [Color.black.opacity(0.30), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )

            HStack(spacing: RuulSpacing.s2) {
                if isHostedByMe {
                    badge(icon: "star.fill", text: "Hosteas", tint: .ruulAccentPrimary)
                }
                if event.status == .inProgress {
                    livePill
                }
                if event.status == .cancelled {
                    badge(icon: "xmark.circle.fill", text: "Cancelado", tint: .ruulSemanticError)
                }
            }
            .padding(RuulSpacing.s3)
        }
    }

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

    // MARK: - Content section

    private var content: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dateDescription)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(event.title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let location = event.locationName, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }

            if confirmedCount > 0 || !attendeeAvatars.isEmpty || (myStatus != nil && myStatus != .pending) {
                footer
            }
        }
        .padding(RuulSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer (social proof + my RSVP)

    private var footer: some View {
        HStack(spacing: RuulSpacing.s3) {
            if !attendeeAvatars.isEmpty {
                RuulAvatarStack(people: attendeeAvatars, size: .small, maxVisible: 4)
            }
            if confirmedCount > 0 {
                Text("\(confirmedCount) van")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            Spacer(minLength: 0)
            if let myStatus, myStatus != .pending {
                myRSVPPill(myStatus)
            }
        }
        .padding(.top, RuulSpacing.s2)
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
        return "\(event.startsAt.ruulShortDate.uppercased()) · \(event.startsAt.ruulShortTime)"
    }

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundStyle(Color.ruulTextInverse)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint, in: Capsule())
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.ruulSemanticError)
                .frame(width: 6, height: 6)
            Text("EN VIVO")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(Color.ruulTextInverse)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.65), in: Capsule())
    }

    private func myRSVPPill(_ status: RSVPStatus) -> some View {
        let (icon, tint, label): (String, Color, String) = {
            switch status {
            case .going:    return ("checkmark", .ruulSemanticSuccess, "Vas")
            case .maybe:    return ("questionmark", .ruulSemanticWarning, "Tal vez")
            case .declined: return ("xmark", .ruulSemanticError, "No vas")
            case .pending:  return ("circle", .ruulTextTertiary, "")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
