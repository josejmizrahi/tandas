import Foundation

/// Every consequence the rule engine can execute when a rule's conditions
/// match. Rules can chain multiple consequences (all execute).
///
/// Cases marked **(V1)** have a ConsequenceExecutor implementation in
/// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError`; rules
/// using them are skipped with a structured log line so the architecture
/// stays V4-ready without silently failing in production.
public enum ConsequenceType: String, Codable, Sendable, Hashable, CaseIterable {

    // MARK: - V1 (only `fine` is implemented)

    /// (V1) Create a row in `fines` table with status `proposed`. The
    /// fine_review_periods row gives host 24h to review before auto-
    /// officializing.
    /// Config (flat fee): `{ "amount": 200 }`
    /// Config (escalating): `{ "baseAmount": 200, "stepAmount": 50, "stepMinutes": 30 }`
    case fine                    = "fine"

    // MARK: - Reserved for future phases

    case loseTurn                = "loseTurn"
    case losePriority            = "losePriority"
    case serviceCompensation     = "serviceCompensation"
    case blockTemporary          = "blockTemporary"
    case reciprocity             = "reciprocity"
    case logOnly                 = "logOnly"
    case sumPoints               = "sumPoints"
    case subtractPoints          = "subtractPoints"
    case sendNotification        = "sendNotification"
    case startVote               = "startVote"
    case createEvent             = "createEvent"
    case assignSlot              = "assignSlot"
    case transferRight           = "transferRight"
    case callWebhook             = "callWebhook"

    public var isImplementedInV1: Bool { self == .fine }
}
