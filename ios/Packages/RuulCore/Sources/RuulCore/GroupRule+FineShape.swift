import Foundation

public extension GroupRule {
    /// Typed view over `consequences[0].config` for `fine` consequences. The
    /// UI consumes this to decide flat-editable vs escalating-readonly; the
    /// repository validates against the same enum before issuing UPDATEs.
    public enum FineShape: Sendable, Equatable {
        case none
        case flat(amount: Int)
        case escalating(base: Int, step: Int, stepMinutes: Int)
        /// Recognised as a fine but with a config we do not know how to
        /// edit (e.g., future schema). UI must show read-only.
        case unknown(rawConfig: ConsequenceEnvelope.Config?)
    }

    /// Parses `consequences[0].config` into a typed shape. Only the first
    /// consequence is inspected — V1 rules carry exactly one. Non-fine first
    /// consequences and empty consequence arrays both yield `.none`.
    public var fineShape: FineShape {
        guard let first = consequences.first, first.type == "fine" else {
            return .none
        }
        let cfg = first.config

        if let amount = cfg?.amount {
            return .flat(amount: amount)
        }
        if let base = cfg?.baseAmount,
           let step = cfg?.stepAmount,
           let mins = cfg?.stepMinutes {
            return .escalating(base: base, step: step, stepMinutes: mins)
        }
        return .unknown(rawConfig: cfg)
    }

    /// Returns a copy of this rule with `enabled` set to the given value.
    /// Used by EditRulesCoordinator for the optimistic-toggle path. Since
    /// `GroupRule` properties are `let`, this constructs a new instance.
    public func withEnabled(_ enabled: Bool) -> GroupRule {
        GroupRule(
            id: id,
            groupId: groupId,
            code: code,
            title: title,
            description: description,
            enabled: enabled,
            isActive: isActive,
            action: action,
            consequences: consequences
        )
    }
}
