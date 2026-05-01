import SwiftUI

/// Compact card representing a single event in lists. Tap → detail.
struct EventCard: View {
    let event: Event
    let myStatus: RSVPStatus?
    let isHostedByMe: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.s4) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: RuulSpacing.s2) {
                        Text(event.title)
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(1)
                        if isHostedByMe {
                            Text("Hosteas")
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulAccentPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.ruulAccentSubtle, in: Capsule())
                        }
                    }
                    Text(event.startsAt.ruulRelativeDescription)
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if let location = event.locationName {
                        Label(location, systemImage: "mappin")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                statusBadge
            }
            .padding(RuulSpacing.s4)
            .ruulGlass(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous),
                material: .regular,
                interactive: true
            )
        }
        .buttonStyle(.ruulPress)
    }

    private var cover: some View {
        let cover = RuulCoverCatalog.cover(named: event.coverImageName)
        return RuulCoverView(cover)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = myStatus, status != .pending {
            Image(systemName: badgeIcon(for: status))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(badgeColor(for: status))
                .frame(width: 28, height: 28)
                .background(badgeColor(for: status).opacity(0.15), in: Circle())
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private func badgeIcon(for status: RSVPStatus) -> String {
        switch status {
        case .going:    return "checkmark"
        case .maybe:    return "questionmark"
        case .declined: return "xmark"
        case .pending:  return "circle"
        }
    }

    private func badgeColor(for status: RSVPStatus) -> Color {
        switch status {
        case .going:    return .ruulSemanticSuccess
        case .maybe:    return .ruulSemanticWarning
        case .declined: return .ruulSemanticError
        case .pending:  return .ruulTextTertiary
        }
    }
}
