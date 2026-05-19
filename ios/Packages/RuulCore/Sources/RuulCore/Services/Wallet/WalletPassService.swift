import Foundation
import OSLog

/// Generates Apple Wallet `.pkpass` files for event RSVPs. V1 ships a stub
/// because Apple Developer Pass Type ID + signing cert aren't configured.
/// See Plans/EventLayerV1.md §1.3 for the V1.x setup steps.
public protocol WalletPassService: Sendable {
    var isAvailable: Bool { get }
    func generatePass(for event: Event, member: Member) async -> URL?
}

/// V1 stub. `isAvailable` returns false so the "Pase de Wallet" overflow
/// item never lights up in the universal detail view until the real
/// implementation is wired.
public final class StubWalletPassService: WalletPassService {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "wallet")

    public init() {}

    public var isAvailable: Bool { false }

    public func generatePass(for event: Event, member: Member) async -> URL? {
        log.debug("Wallet pass would be generated for event=\(event.id), member=\(member.id)")
        return nil
    }
}
