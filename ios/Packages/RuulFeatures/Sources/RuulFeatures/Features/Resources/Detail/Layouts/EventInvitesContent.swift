import SwiftUI
import MapKit
import RuulUI
import RuulCore

/// Hand-crafted, Apple-Invites-inspired body for event detail surfaces.
/// Replaces the catalog-driven section stack for events: instead of a
/// long ladder of card-on-card sections with shouty headers, the page
/// reads as a single magazine column with typography hierarchy doing
/// the work.
///
/// Vertical rhythm (top → bottom):
///   1. Title block       — date · title · countdown · status pills
///   2. Description       — plain body text, no chrome
///   3. Location card     — Apple-Invites map preview (when coords set)
///   4. Capacity caption  — single-line bar (when capacity_max set)
///   5. RSVP intent       — the primary CTA, large and obvious
///   6. Attendee strip    — horizontal avatars + "Ver todos" sheet
///   7. Check-in card     — only inside the visibility window
///   8. Host actions      — host-only quick-action stack
///   9. Activity feed     — quiet bottom-of-page
///
/// All event-specific state comes from `\.eventInteractor`. Sheet
/// presenters route through `\.eventDetailPresenter` so the host
/// shell (`EventDetailHost`) owns the bindings — this view stays
/// pure layout, no @State sheet routes.
public struct EventInvitesContent: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
            EventHeroTitleBlock(context: context)

            descriptionParagraph

            locationCard

            capacityLine

            rsvpIntent

            attendeesStrip

            checkInBlock

            hostActionsBlock

            activitySection
        }
    }

    // MARK: - Description

    @ViewBuilder
    private var descriptionParagraph: some View {
        if let body = descriptionBody {
            Text(body)
                .ruulTextStyle(RuulTypography.bodyLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RuulSpacing.xxs)
                .accessibilityLabel("Descripción")
                .accessibilityValue(body)
        }
    }

    private var descriptionBody: String? {
        let raw = liveEvent?.description ?? context.resource.metadata["description"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Location

    @ViewBuilder
    private var locationCard: some View {
        if let name = locationName {
            EventLocationCard(
                locationName: name,
                coordinate: locationCoordinate,
                onOpenMaps: openMaps
            )
        }
    }

    private var locationName: String? {
        let raw = liveEvent?.locationName
            ?? context.resource.metadata["location_name"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var locationCoordinate: CLLocationCoordinate2D? {
        if let event = liveEvent,
           let lat = event.locationLat, let lng = event.locationLng {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return nil
    }

    private func openMaps() {
        guard let name = locationName else { return }
        if let coord = locationCoordinate {
            let placemark = MKPlacemark(coordinate: coord)
            let mapItem = MKMapItem(placemark: placemark)
            mapItem.name = name
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
            return
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.apple.com/?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Capacity

    @ViewBuilder
    private var capacityLine: some View {
        if let capacityMax = liveEvent?.capacityMax {
            CapacityProgressSectionView(context: context)
        } else if context.resource.metadata["capacity_max"]?.intValue != nil {
            CapacityProgressSectionView(context: context)
        }
    }

    // MARK: - RSVP

    @ViewBuilder
    private var rsvpIntent: some View {
        if let interactor, let event = interactor.event as Event? {
            EventRSVPStateView(
                status: interactor.myRSVP?.status ?? .pending,
                event: event,
                walletAvailable: interactor.walletAvailable,
                isAtCapacity: isAtCapacity(interactor: interactor),
                plusOnes: pendingPlusOnesBinding(),
                onChange: { newStatus in
                    Task {
                        await interactor.setRSVP(
                            newStatus,
                            plusOnes: interactor.myRSVP?.plusOnes ?? 0,
                            reason: nil
                        )
                    }
                },
                onAddToWallet: { presenter?.onAddToWallet() },
                onShowQR: { presenter?.onPresentMemberQR() }
            )
        }
    }

    /// Plus-ones binding bridges interactor truth to the local stepper.
    /// Reads from `interactor.myRSVP?.plusOnes`; writing it back queues
    /// an optimistic `setRSVP` so the server has the new count without
    /// requiring the user to tap a "Voy" button again.
    private func pendingPlusOnesBinding() -> Binding<Int> {
        Binding(
            get: { interactor?.myRSVP?.plusOnes ?? 0 },
            set: { newValue in
                guard let interactor else { return }
                let status = interactor.myRSVP?.status ?? .going
                Task { await interactor.setRSVP(status, plusOnes: newValue, reason: nil) }
            }
        )
    }

    private func isAtCapacity(interactor: any EventInteractor) -> Bool {
        guard let max = interactor.event.capacityMax else { return false }
        let seatsTaken = interactor.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes }
        let myExisting = (interactor.myRSVP?.status == .going)
            ? (1 + (interactor.myRSVP?.plusOnes ?? 0))
            : 0
        return (seatsTaken - myExisting + 1) > max
    }

    // MARK: - Attendees

    @ViewBuilder
    private var attendeesStrip: some View {
        if let interactor, !interactor.rsvps.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Asistentes")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(.horizontal, RuulSpacing.xxs)
                RSVPAvatarStrip(
                    rsvps: interactor.rsvps,
                    memberDirectory: context.memberDirectory,
                    onSelectMember: context.onSelectMember,
                    onSeeAll: { presenter?.onPresentAttendeesList() }
                )
            }
        }
    }

    // MARK: - Check-in

    @ViewBuilder
    private var checkInBlock: some View {
        CheckInSectionView(context: context)
    }

    // MARK: - Host actions

    @ViewBuilder
    private var hostActionsBlock: some View {
        if interactor?.viewerIsHost == true {
            HostActionsSectionView(context: context)
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        ActivitySectionView(context: context)
    }

    // MARK: - Helpers

    private var liveEvent: Event? { interactor?.event }
}
