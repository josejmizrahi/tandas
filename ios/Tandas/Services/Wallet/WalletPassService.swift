import Foundation
import OSLog

/// Generates Apple Wallet `.pkpass` files for event RSVPs. V1 ships a stub
/// because Apple Developer Pass Type ID + signing cert aren't configured.
/// See Plans/EventLayerV1.md §1.3 for the V1.x setup steps.
protocol WalletPassService: Sendable {
    var isAvailable: Bool { get }
    func generatePass(for event: Event, member: Member) async -> URL?
}

/// V1 stub. `isAvailable` returns false so the "Add to Wallet" button never
/// appears in `EventRSVPStateView` until the real implementation is wired.
final class StubWalletPassService: WalletPassService {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "wallet")

    var isAvailable: Bool { false }

    func generatePass(for event: Event, member: Member) async -> URL? {
        log.debug("Wallet pass would be generated for event=\(event.id), member=\(member.id)")
        return nil
    }
}
