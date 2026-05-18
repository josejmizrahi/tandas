import Foundation

public extension GroupRule {
    /// Typed view over `consequences[0].config` for `fine` consequences. The
    /// UI consumes this to decide flat-editable vs escalating-readonly; the
    /// repository validates against the same enum before issuing UPDATEs.
    enum FineShape: Sendable, Equatable {
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
    ///
    /// **Deprecated since 2026-05-18** — violates `RulesVsMoneyDoctrine.md`
    /// Axioma 1 by exposing fine-only branching as a property of the
    /// universal `GroupRule`. Phase 2 of `RulesFinesRefactorPlan.md` moves
    /// this to `FineConsequenceParser.shape(of:)` so the fine awareness
    /// stays in fine-coupled UI surfaces (composer, params editor) instead
    /// of leaking into the core model.
    var fineShape: FineShape {
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

    /// Returns a copy of this rule with `isActive` set to the given value.
    /// Used by EditRulesCoordinator for the optimistic-toggle path. Since
    /// `GroupRule` properties are `let`, this constructs a new instance.
    func withIsActive(_ isActive: Bool) -> GroupRule {
        GroupRule(
            id: id,
            groupId: groupId,
            slug: slug,
            name: name,
            isActive: isActive,
            trigger: trigger,
            conditions: conditions,
            consequences: consequences,
            exceptions: exceptions,
            conditionsTree: conditionsTree,
            moduleKey: moduleKey,
            resourceId: resourceId,
            seriesId: seriesId,
            membershipId: membershipId
        )
    }
}
