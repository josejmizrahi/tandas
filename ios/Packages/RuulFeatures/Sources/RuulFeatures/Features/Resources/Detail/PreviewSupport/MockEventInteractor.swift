#if DEBUG
import Foundation
import Observation
import RuulCore

/// In-memory `EventInteractor` for SwiftUI previews and tests. Stores
/// canned event + RSVP state and records mutations into the event log
/// without doing any network or persistence work.
///
/// Not shipped in release builds (gated by `#if DEBUG`). Production
/// callers use `EventDetailCoordinator` which conforms to the same
/// protocol via the live repositories.
@Observable
@MainActor
public final class MockEventInteractor: EventInteractor {
    public var event: Event
    public var rsvps: [RSVP]
    public var myRSVP: RSVP?
    public var viewerIsHost: Bool
    public var isMutating: Bool = false
    public var walletAvailable: Bool

    /// Per-call log of mutating method names — handy for preview-driven
    /// debugging and for assertions in future capability-section tests.
    public private(set) var log: [String] = []

    public init(
        event: Event,
        rsvps: [RSVP] = [],
        myRSVP: RSVP? = nil,
        viewerIsHost: Bool = false,
        walletAvailable: Bool = false
    ) {
        self.event = event
        self.rsvps = rsvps
        self.myRSVP = myRSVP
        self.viewerIsHost = viewerIsHost
        self.walletAvailable = walletAvailable
    }

    public func setRSVP(_ status: RSVPStatus, plusOnes: Int, reason: String?) async {
        log.append("setRSVP(\(status.rawValue), plusOnes:\(plusOnes))")
        let updated = RSVP(
            id: myRSVP?.id ?? UUID(),
            eventId: event.id,
            userId: myRSVP?.userId ?? UUID(),
            status: status,
            respondedAt: .now,
            cancelledReason: reason,
            plusOnes: plusOnes
        )
        myRSVP = updated
        if let idx = rsvps.firstIndex(where: { $0.userId == updated.userId }) {
            rsvps[idx] = updated
        } else {
            rsvps.append(updated)
        }
    }

    public func selfCheckIn(locationVerified: Bool) async {
        log.append("selfCheckIn(locationVerified:\(locationVerified))")
    }

    public func hostMarkCheckIn(memberId: UUID) async {
        log.append("hostMarkCheckIn(memberId:\(memberId))")
    }

    public func sendHostReminders() async -> Int {
        log.append("sendHostReminders")
        return rsvps.filter { $0.status == .pending }.count
    }

    public func cancelEvent(reason: String?) async {
        log.append("cancelEvent(reason:\(reason ?? "nil"))")
    }

    public func closeEvent(autoGenerateEnabled: Bool) async {
        log.append("closeEvent(autoGenerateEnabled:\(autoGenerateEnabled))")
    }

    public func toggleAutoGenerate(_ enabled: Bool) async {
        log.append("toggleAutoGenerate(\(enabled))")
    }

    public func promoteFromWaitlist() async {
        log.append("promoteFromWaitlist")
    }

    public func generateWalletPass() async -> URL? {
        log.append("generateWalletPass")
        return nil
    }
}

public extension MockEventInteractor {
    /// Canned upcoming event used by `UniversalResourceDetailView` previews.
    static func previewUpcoming(viewerIsHost: Bool = false) -> MockEventInteractor {
        let userId = UUID()
        let event = Event(
            id: UUID(),
            groupId: UUID(),
            title: "Tanda de los jueves",
            coverImageName: "sunset",
            description: "Cena rotativa entre amigos. Llegada a las 8, comida a las 9.",
            startsAt: Date.now.addingTimeInterval(2 * 86_400 + 3 * 3_600),
            durationMinutes: 240,
            locationName: "Casa de Jose",
            locationLat: 19.4326,
            locationLng: -99.1332,
            hostId: viewerIsHost ? userId : UUID(),
            createdAt: .now.addingTimeInterval(-7 * 86_400),
            capacityMax: 8,
            allowPlusOnes: true,
            maxPlusOnesPerMember: 2
        )
        let goingRSVPs = (0..<4).map { idx in
            RSVP(
                id: UUID(),
                eventId: event.id,
                userId: UUID(),
                status: .going,
                respondedAt: .now.addingTimeInterval(-Double(idx) * 3_600),
                plusOnes: idx == 0 ? 1 : 0
            )
        }
        let pendingRSVPs = (0..<2).map { _ in
            RSVP(
                id: UUID(),
                eventId: event.id,
                userId: UUID(),
                status: .pending,
                respondedAt: nil
            )
        }
        let my = RSVP(
            id: UUID(),
            eventId: event.id,
            userId: userId,
            status: viewerIsHost ? .going : .pending,
            respondedAt: viewerIsHost ? .now : nil
        )
        return MockEventInteractor(
            event: event,
            rsvps: goingRSVPs + pendingRSVPs + [my],
            myRSVP: my,
            viewerIsHost: viewerIsHost,
            walletAvailable: true
        )
    }
}
#endif
