import SwiftUI
import RuulUI
import RuulCore

/// Check-in surface for event-shaped resources. Visible from 2h before
/// until 12h after the event start. Renders two sub-blocks driven by
/// the viewer's relationship to the event:
///
///   - **Guest**: "Marca tu llegada" tile when the user has RSVP'd
///     `.going` and hasn't checked in yet. Becomes a "Llegaste a las HH:MM"
///     confirmation card after.
///   - **Host**: "Marca llegadas" roll of confirmed-but-not-checked-in
///     attendees with a per-row toggle. Mirrors the host roll from the
///     legacy `CheckInSection`.
///
/// Drives entirely off `\.eventInteractor` — returns `EmptyView` when
/// the interactor is missing (no event context to read from). Gated by
/// the `check_in` capability declared in `CapabilityCatalog.v1`.
public struct CheckInSectionView: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "check_in",
        priority: 250,
        tabId: "people",
        isEnabledFor: { caps in caps.contains(CapabilityID.checkIn) },
        render: { ctx in AnyView(CheckInSectionView(context: ctx)) }
    )

    public var body: some View {
        if let interactor, isVisible(for: interactor.event) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                guestBlock(interactor: interactor)
                if interactor.viewerIsHost {
                    hostBlock(interactor: interactor)
                }
            }
        }
    }

    // MARK: - Guest block

    @ViewBuilder
    private func guestBlock(interactor: any EventInteractor) -> some View {
        if let myRSVP = interactor.myRSVP, myRSVP.status == .going {
            if myRSVP.isCheckedIn, let arrived = myRSVP.arrivedAt {
                checkedInCard(arrivedAt: arrived)
            } else {
                notYetCheckedInCard(interactor: interactor)
            }
        }
    }

    private func notYetCheckedInCard(interactor: any EventInteractor) -> some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Marca tu llegada")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                HStack(spacing: RuulSpacing.xs) {
                    RuulButton(
                        "Ya llegué",
                        systemImage: "checkmark",
                        style: .primary,
                        size: .medium,
                        fillsWidth: true
                    ) {
                        Task { await interactor.selfCheckIn(locationVerified: false) }
                    }
                    RuulButton(
                        "Mi QR",
                        systemImage: "qrcode",
                        style: .glass,
                        size: .medium
                    ) {
                        presenter?.onPresentMemberQR()
                    }
                }
            }
        }
    }

    private func checkedInCard(arrivedAt: Date) -> some View {
        RuulCard(.tile, tint: .ruulPositive) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulPositive)
                    .accessibilityHidden(true)
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

    // MARK: - Host block

    @ViewBuilder
    private func hostBlock(interactor: any EventInteractor) -> some View {
        let confirmedNotCheckedIn = interactor.rsvps.filter { $0.status == .going && !$0.isCheckedIn }
        if !confirmedNotCheckedIn.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                sectionHeader("MARCA LLEGADAS")
                VStack(spacing: 0) {
                    ForEach(confirmedNotCheckedIn, id: \.id) { rsvp in
                        hostRow(rsvp: rsvp, interactor: interactor)
                        if rsvp.id != confirmedNotCheckedIn.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(RuulSpacing.sm)
                .background(
                    Color.ruulBackgroundRecessed,
                    in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                )
            }
        }
    }

    private func hostRow(rsvp: RSVP, interactor: any EventInteractor) -> some View {
        let profile = context.memberDirectory[rsvp.userId]
        let name = profile?.displayName ?? "Miembro"
        return HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: name, imageURL: profile?.avatarURL, size: .small)
            Text(name)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { rsvp.isCheckedIn },
                    set: { newValue in
                        guard newValue else { return }
                        Task { await interactor.hostMarkCheckIn(memberId: rsvp.userId) }
                    }
                )
            )
            .labelsHidden()
            .tint(Color.ruulPositive)
            .accessibilityLabel("Marcar llegada de \(name)")
        }
        .padding(.vertical, RuulSpacing.xs)
    }

    // MARK: - Visibility window

    /// Visible from 2h before start until 12h after.
    private func isVisible(for event: Event) -> Bool {
        let now = Date.now
        let openWindow  = event.startsAt.addingTimeInterval(-2 * 3600)
        let closeWindow = event.startsAt.addingTimeInterval(12 * 3600)
        return now >= openWindow && now <= closeWindow
    }
}
