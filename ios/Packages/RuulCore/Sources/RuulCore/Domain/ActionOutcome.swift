import Foundation

/// D.22 Action Governance Layer — canonical UI-facing result of calling
/// `request_or_execute_action(...)`. Replaces ad-hoc per-RPC responses
/// for every governable action (`action_catalog` keys).
///
/// Each case maps 1:1 to a `status` value returned by the backend:
/// - `directAllowed` → caller may proceed with `plan.executableRPC`.
/// - `decisionOpened` → a vote was created; surface it in the UI.
/// - `denied`        → caller lacks the required permission.
/// - `unsupported`   → unknown action_key (catalog miss).
/// - `failed`        → start_vote / template lookup failed.
///
/// Doctrine: `doctrine_action_governance_tiers.md`.
public enum ActionOutcome: Sendable, Equatable {
    case directAllowed(plan: ActionPlan)
    case decisionOpened(DecisionOpenedDetails)
    case denied(reason: String, missingPermission: String?)
    case unsupported(reason: String, actionKey: String)
    case failed(reason: String, message: String?)
}

/// Direct-execute envelope. The UI proceeds with `executableRPC` (the
/// repository method that wraps the underlying RPC, e.g. `archiveResource`).
/// `reason` is one of: `direct_by_default`, `self_only_direct`,
/// `founder_emergency_override`.
public struct ActionPlan: Sendable, Equatable {
    public let actionKey: String
    public let executableRPC: String?
    public let targetKind: String?
    public let targetId: UUID?
    public let reason: String
    public let isFounder: Bool
    public let isAdmin: Bool
    public let riskLevel: String?

    public init(
        actionKey: String,
        executableRPC: String?,
        targetKind: String?,
        targetId: UUID?,
        reason: String,
        isFounder: Bool,
        isAdmin: Bool,
        riskLevel: String?
    ) {
        self.actionKey = actionKey
        self.executableRPC = executableRPC
        self.targetKind = targetKind
        self.targetId = targetId
        self.reason = reason
        self.isFounder = isFounder
        self.isAdmin = isAdmin
        self.riskLevel = riskLevel
    }
}

/// Decision-opened envelope. The UI shows "se abrió una decisión" and
/// can deep-link to `decisionId`.
public struct DecisionOpenedDetails: Sendable, Equatable {
    public let decisionId: UUID
    public let templateKey: String?
    public let actionKey: String
    public let method: String?
    public let thresholdPct: Decimal?
    public let quorumPct: Decimal?

    public init(
        decisionId: UUID,
        templateKey: String?,
        actionKey: String,
        method: String?,
        thresholdPct: Decimal?,
        quorumPct: Decimal?
    ) {
        self.decisionId = decisionId
        self.templateKey = templateKey
        self.actionKey = actionKey
        self.method = method
        self.thresholdPct = thresholdPct
        self.quorumPct = quorumPct
    }
}

extension ActionOutcome {
    /// True for the happy paths (`directAllowed` and `decisionOpened`).
    public var isAllowed: Bool {
        switch self {
        case .directAllowed, .decisionOpened: return true
        case .denied, .unsupported, .failed:  return false
        }
    }
}
