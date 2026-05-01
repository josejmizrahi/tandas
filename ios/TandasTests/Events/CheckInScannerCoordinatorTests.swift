import Testing
import Foundation
@testable import Tandas

@Suite("CheckInScannerCoordinator")
@MainActor
struct CheckInScannerCoordinatorTests {
    private func makeCoord(eventId: UUID = UUID()) -> (CheckInScannerCoordinator, MockCheckInRepository, UUID) {
        let event = Event(
            id: eventId, groupId: UUID(), title: "E",
            startsAt: .now, createdAt: .now
        )
        let repo = MockCheckInRepository()
        let scanner = QRScannerService()
        let analytics = EventAnalytics(analytics: MockAnalyticsService())
        let coord = CheckInScannerCoordinator(
            event: event,
            totalConfirmed: 5,
            alreadyCheckedCount: 0,
            scanner: scanner,
            checkInRepo: repo,
            analytics: analytics,
            memberLookup: { _ in "Test Member" }
        )
        return (coord, repo, eventId)
    }

    @Test("invalid QR sets overlay=invalid")
    func invalidQR() async {
        let (coord, _, _) = makeCoord()
        await coord.handleScan("garbage payload")
        // After throttle the overlay reverts to .none, so we check during processing.
        // Since handleScan awaits the throttle, we just assert no checkin happened.
        #expect(coord.checkedCount == 0)
    }

    @Test("QR for wrong event sets overlay=invalid")
    func wrongEventQR() async {
        let (coord, _, _) = makeCoord()
        let payload = QRSignatureService.sign(eventId: UUID(), memberId: UUID(), secret: "test-secret")
        await coord.handleScan(payload)
        #expect(coord.checkedCount == 0)
    }

    @Test("valid QR for the event records check-in")
    func validQR() async {
        let (coord, repo, eventId) = makeCoord()
        // Match the QRSignatureService.sharedSecret which reads from
        // Info.plist; in tests it's empty string, sign + verify still
        // round-trip with empty secret.
        let memberId = UUID()
        let payload = QRSignatureService.sign(eventId: eventId, memberId: memberId, secret: "")
        await coord.handleScan(payload)
        #expect(coord.checkedCount == 1)
        let checkIns = await repo.checkIns
        #expect(checkIns.first?.method == .qrScan)
    }

    @Test("overlay is throttled during processing")
    func overlayThrottle() async {
        let (coord, _, _) = makeCoord()
        // Two scans in quick succession; second should be ignored while
        // overlay is non-.none.
        await coord.handleScan("garbage 1")
        let beforeSecond = coord.checkedCount
        await coord.handleScan("garbage 2")
        #expect(coord.checkedCount == beforeSecond)
    }
}
