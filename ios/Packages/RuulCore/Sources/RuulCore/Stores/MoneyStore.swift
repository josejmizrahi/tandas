import Foundation
import Observation

/// `@MainActor` store for the caller's money state inside a single
/// group — balance scalar + list of open obligations. Both reads come
/// from canonical RPCs; iOS never derives these locally (doctrine §5+§6).
///
/// Refreshes are explicit: call `refresh(groupId:membershipId:)` after
/// any of `record_expense`, `record_settlement`, `accept_invite`,
/// `leave_group`, `create_group`. Foundation does not subscribe to
/// realtime — that lands in a later slice.
@MainActor
@Observable
public final class MoneyStore {
    public private(set) var balance: Decimal?
    public private(set) var obligations: [ObligationSummary] = []
    public private(set) var phase: StorePhase = .idle

    private let repository: CanonicalMoneyRepository

    public init(repository: CanonicalMoneyRepository) {
        self.repository = repository
    }

    /// Loads both `member_balance_in_group` and `member_obligation_summary`
    /// concurrently. Either failure flips the whole store into `.failed`
    /// so the UI doesn't render a mixed half-stale state.
    public func refresh(groupId: UUID, membershipId: UUID) async {
        if balance == nil && obligations.isEmpty {
            phase = .loading
        }
        do {
            async let balanceTask = repository.balance(groupId: groupId, membershipId: membershipId)
            async let obligationsTask = repository.obligationSummary(groupId: groupId, membershipId: membershipId)
            let (balance, obligations) = try await (balanceTask, obligationsTask)
            self.balance = balance
            self.obligations = obligations
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Clears local state — call when leaving a group or switching the
    /// focused group so stale numbers don't flash before the next refresh.
    public func clear() {
        balance = nil
        obligations = []
        phase = .idle
    }
}
