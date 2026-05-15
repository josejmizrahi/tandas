import Foundation

/// Every consequence the rule engine can execute when a rule's conditions
/// match. Rules can chain multiple consequences (all execute).
///
/// Cases marked **(V1)** have a ConsequenceExecutor implementation in
/// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError`; rules
/// using them are skipped with a structured log line so the architecture
/// stays V4-ready without silently failing in production.
// @codegen:enum
public enum ConsequenceType: Codable, Sendable, Hashable {

    // MARK: - V1 (only `fine` is implemented)

    /// (V1) Create a row in `fines` table with status `proposed`. The
    /// fine_review_periods row gives host 24h to review before auto-
    /// officializing.
    /// Config (flat fee): `{ "amount": 200 }`
    /// Config (escalating): `{ "baseAmount": 200, "stepAmount": 50, "stepMinutes": 30 }`
    case fine

    // MARK: - Reserved for future phases

    case loseTurn
    case losePriority
    case serviceCompensation
    case blockTemporary
    case reciprocity
    case logOnly
    case sumPoints
    case subtractPoints
    case sendNotification
    case startVote
    case createEvent
    case assignSlot
    case transferRight
    case callWebhook

    // MARK: - Money / Governance (mig 00193, expense_threshold_warning pilot)

    /// Emits a `warningEmitted` system_event scoped to the rule's target.
    /// Surfaces in the activity feed; visible to admins via rule_evaluations.
    /// No money, no vote — pure visibility signal. Per Governance.md §5.1.
    case emitWarning

    case unknown(String)
}
