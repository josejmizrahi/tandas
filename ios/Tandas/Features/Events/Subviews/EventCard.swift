import SwiftUI

/// Full-tile event card. Apple Sports pattern: the cover IS the card —
/// content is overlaid in white over a vignette gradient. No body section,
/// no white space. Each card has its own color identity from the cover.
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
            ZStack(alignment: .bottomLeading) {
                cover
                    .aspectRatio(16/11, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                // Vignette: bottom 60% darkens for white-text legibility,
                // top stays clean so status badges read against the cover hue.
                LinearGradient(
                    stops: [
                        .init(color: .clear,                       location: 0.00),
                        .init(color: .clear,                       location: 0.30),
                        .init(color: .ruulImageScrim(.light),      location: 0.55),
                        .init(color: .ruulImageScrim(.deep),       location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                topBadgesOverlay
                bottomContentOverlay
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
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
            HStack(spacing: RuulSpacing.s2) {
                if event.status == .inProgress {
                    livePill
                }
                if event.status == .cancelled {
                    overlayBadge(icon: "xmark", text: "Cancelado", tint: Color.ruulSemanticError)
                }
                if event.status == .closed {
                    overlayBadge(icon: "checkmark", text: "Cerrado", tint: Color.ruulImageScrim(.badge))
                }
                Spacer()
                if isHostedByMe {
                    overlayBadge(icon: "star.fill", text: "Hosteas", tint: Color.ruulImageScrim(.badge))
                }
            }
            .padding(RuulSpacing.s3)
            Spacer()
        }
    }

    // MARK: - Bottom content (date / title / meta / footer all in white)

    private var bottomContentOverlay: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateDescription)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulOnImage.opacity(0.85))

                Text(event.title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulOnImage)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: Color.ruulImageScrim(.light), radius: 2, x: 0, y: 1)
            }

            HStack(spacing: RuulSpacing.s3) {
                if let location = event.locationName, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ruulOnImage.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if confirmedCount > 0 {
                    Text("\(confirmedCount) van")
                        .ruulTextStyle(RuulTypography.statSmall)
                        .foregroundStyle(Color.ruulOnImage)
                }
                if let myStatus, myStatus != .pending {
                    myRSVPPill(myStatus)
                }
            }
        }
        .padding(RuulSpacing.s4)
    }

    // MARK: - Helpers

    private var dateDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.startsAt) {
            return "HOY · \(event.startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(event.startsAt) {
            return "MAÑANA · \(event.startsAt.ruulShortTime)"
        }
        return "\(event.startsAt.ruulShortDate.uppercased()) · \(event.startsAt.ruulShortTime)"
    }

    private func overlayBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(Color.ruulOnImage)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint, in: Capsule())
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.ruulOnImage)
                .frame(width: 6, height: 6)
            Text("EN VIVO")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(Color.ruulOnImage)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.ruulSemanticError, in: Capsule())
    }

    private func myRSVPPill(_ status: RSVPStatus) -> some View {
        let (icon, label): (String, String) = {
            switch status {
            case .going:    return ("checkmark", "Vas")
            case .maybe:    return ("questionmark", "Tal vez")
            case .declined: return ("xmark", "No vas")
            case .pending:  return ("circle", "")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.ruulOnImage)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.ruulOnImage.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(Color.ruulOnImage.opacity(0.30), lineWidth: 0.5))
    }
}
