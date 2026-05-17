import Foundation
import OSLog

/// Generates Apple Wallet `.pkpass` files for event RSVPs.
///
/// `StubWalletPassService` is the canonical implementation in all
/// environments today — it gates the "Add to Wallet" UI via
/// `isAvailable == false`, so the button never appears. This is **not**
/// technical debt; it is a Null Object placeholder until Apple Developer
/// Pass Type ID + signing certificate are provisioned and a
/// `LiveWalletPassService` lands. Swap the binding in `TandasApp` (and
/// in the `AppState.init` default) when that happens.
public protocol WalletPassService: Sendable {
    var isAvailable: Bool { get }
    func generatePass(for event: Event, member: Member) async -> URL?
}

public final class StubWalletPassService: WalletPassService {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "wallet")

    public init() {}

    public var isAvailable: Bool { false }

    public func generatePass(for event: Event, member: Member) async -> URL? {
        log.debug("Wallet pass would be generated for event=\(event.id), member=\(member.id)")
        return nil
    }
}
