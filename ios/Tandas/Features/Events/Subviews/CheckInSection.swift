import SwiftUI

/// Check-in section for both guests and hosts. Visible from 2h before until
/// 12h after the event start.
struct CheckInSection: View {
    let event: Event
    let myRSVP: RSVP?
    let viewerIsHost: Bool
    let confirmedRSVPs: [RSVP]
    let memberLookup: (UUID) -> (name: String, avatarURL: URL?)
    let onSelfCheckIn: () -> Void
    let onShowQR: () -> Void
    let onHostMarkCheckIn: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            if isVisible {
                Text("CHECK-IN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                guestSection
                if viewerIsHost {
                    hostSection
                }
            }
        }
    }

    @ViewBuilder
    private var guestSection: some View {
        if let myRSVP, myRSVP.status == .going {
            if myRSVP.isCheckedIn, let arrived = myRSVP.arrivedAt {
                checkedInCard(arrivedAt: arrived)
            } else {
                notYetCheckedInCard
            }
        }
    }

    private var notYetCheckedInCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                Text("Marca tu llegada")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                HStack(spacing: RuulSpacing.s2) {
                    RuulButton("Ya llegué", systemImage: "checkmark", style: .primary, size: .medium, fillsWidth: true, action: onSelfCheckIn)
                    RuulButton("Mi QR", systemImage: "qrcode", style: .glass, size: .medium, action: onShowQR)
                }
            }
        }
    }

    private func checkedInCard(arrivedAt: Date) -> some View {
        RuulCard(.tile, tint: .ruulSemanticSuccess) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.ruulSemanticSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Llegaste a las \(arrivedAt.ruulShortTime)")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Saluda a los demás")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var hostSection: some View {
        let confirmedNotCheckedIn = confirmedRSVPs.filter { !$0.isCheckedIn }
        if !confirmedNotCheckedIn.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("MARCA LLEGADAS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: 0) {
                    ForEach(confirmedNotCheckedIn, id: \.id) { rsvp in
                        hostRow(for: rsvp)
                        if rsvp.id != confirmedNotCheckedIn.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(RuulSpacing.s3)
                .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            }
        }
    }

    private func hostRow(for rsvp: RSVP) -> some View {
        let info = memberLookup(rsvp.userId)
        return HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: info.name, imageURL: info.avatarURL, size: .small)
            Text(info.name)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Toggle("", isOn: Binding(get: { rsvp.isCheckedIn }, set: { newValue in
                if newValue { onHostMarkCheckIn(rsvp.userId) }
            }))
            .labelsHidden()
            .tint(Color.ruulSemanticSuccess)
        }
        .padding(.vertical, RuulSpacing.s2)
    }

    /// Visible from 2h before start until 12h after.
    private var isVisible: Bool {
        let now = Date.now
        let openWindow = event.startsAt.addingTimeInterval(-2 * 3600)
        let closeWindow = event.startsAt.addingTimeInterval(12 * 3600)
        return now >= openWindow && now <= closeWindow
    }
}
