import Foundation
import OSLog

/// Apple Wallet pass generator.
///
/// V1: stub (returns nil). V2: real `.pkpass` signed by Apple Developer cert
/// served by an Edge Function.
protocol WalletPassGenerator: Sendable {
    func createPass(forEventId eventId: UUID, memberId: UUID) async -> URL?
}

/// V1 stub. Logs the call and returns nil so callers conditionally hide the
/// "Add to Wallet" affordance.
final class StubWalletPassGenerator: WalletPassGenerator {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "wallet")

    func createPass(forEventId eventId: UUID, memberId: UUID) async -> URL? {
        log.debug("Wallet pass would be generated for event=\(eventId), member=\(memberId)")
        return nil
    }
}
