import Foundation
import Observation
import OSLog

@Observable @MainActor
final class CheckInScannerCoordinator {
    enum Overlay: Equatable, Sendable {
        case none
        case success(memberId: UUID, name: String)
        case alreadyCheckedIn(memberId: UUID, name: String)
        case invalid
    }

    private(set) var overlay: Overlay = .none
    private(set) var recentCheckIns: [(memberId: UUID, name: String, at: Date)] = []
    private(set) var checkedCount: Int = 0
    let totalConfirmed: Int

    let event: Event
    let scanner: QRScannerService
    private let checkInRepo: any CheckInRepository
    private let analytics: EventAnalytics
    private let memberLookup: (UUID) -> String
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "checkin.scanner")

    init(
        event: Event,
        totalConfirmed: Int,
        alreadyCheckedCount: Int,
        scanner: QRScannerService,
        checkInRepo: any CheckInRepository,
        analytics: EventAnalytics,
        memberLookup: @escaping (UUID) -> String
    ) {
        self.event = event
        self.totalConfirmed = totalConfirmed
        self.checkedCount = alreadyCheckedCount
        self.scanner = scanner
        self.checkInRepo = checkInRepo
        self.analytics = analytics
        self.memberLookup = memberLookup
        Task { await analytics.qrScannerOpened() }
    }

    func start() async {
        await scanner.start()
    }

    func stop() {
        scanner.stop()
    }

    /// Process a payload scanned by the camera. Verifies signature, calls
    /// repo, displays overlay 1.5s before resuming scan.
    func handleScan(_ payload: String) async {
        guard case .none = overlay else { return }

        guard let parsed = QRSignatureService.verify(payload, secret: QRSignatureService.sharedSecret) else {
            overlay = .invalid
            await analytics.qrScanFailure(reason: .invalidSignature)
            await throttleOverlay()
            return
        }
        guard parsed.eventId == event.id else {
            overlay = .invalid
            await analytics.qrScanFailure(reason: .unknown)
            await throttleOverlay()
            return
        }

        do {
            _ = try await checkInRepo.qrScanCheckIn(eventId: event.id, memberId: parsed.memberId)
            let name = memberLookup(parsed.memberId)
            overlay = .success(memberId: parsed.memberId, name: name)
            recentCheckIns.insert((parsed.memberId, name, .now), at: 0)
            recentCheckIns = Array(recentCheckIns.prefix(3))
            checkedCount += 1
            await analytics.qrScanSuccess()
        } catch EventError.alreadyCheckedIn {
            let name = memberLookup(parsed.memberId)
            overlay = .alreadyCheckedIn(memberId: parsed.memberId, name: name)
            await analytics.qrScanFailure(reason: .alreadyCheckedIn)
        } catch {
            overlay = .invalid
            await analytics.qrScanFailure(reason: .unknown)
        }
        await throttleOverlay()
    }

    private func throttleOverlay() async {
        try? await Task.sleep(for: .milliseconds(1500))
        overlay = .none
        scanner.acknowledgeAndResume()
    }
}
