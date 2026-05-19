import Foundation

/// Fine-aware helper that parses `GroupRule.ConsequenceEnvelope` arrays
/// looking for the first `.fine` consequence and extracting its typed
/// shape (flat / escalating / unknown).
///
/// Lives outside the universal `GroupRule` model per
/// `RulesVsMoneyDoctrine.md` Axioma 1 (Rule ≠ Fine): the parser exists
/// so fine-coupled UI surfaces (composer, params editor, list cards) can
/// branch on shape without dragging fine assumptions into the core model.
///
/// The shape enum (`FineShape`) is colocated here for the same reason —
/// it is the parser's vocabulary, not the rule's.
public enum FineConsequenceParser {

    /// Typed view over `consequences[0].config` for `fine` consequences.
    /// V1 rules carry exactly one consequence; only that one is inspected.
    /// Non-fine first consequences and empty arrays both yield `.none`.
    public enum FineShape: Sendable, Equatable {
        case none
        case flat(amount: Int)
        case escalating(base: Int, step: Int, stepMinutes: Int)
        /// Recognised as a fine but with a config we do not know how to
        /// edit (e.g., future schema). UI must show read-only.
        case unknown(rawConfig: GroupRule.ConsequenceEnvelope.Config?)
    }

    /// Parses the first `.fine` consequence's config into a typed shape.
    public static func shape(
        of consequences: [GroupRule.ConsequenceEnvelope]
    ) -> FineShape {
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

    /// Resolves the display amount (MXN) from the first `.fine`
    /// consequence. Returns `nil` when the rule's first consequence is
    /// not a fine. Falls back from `amount` (flat) to `baseAmount`
    /// (escalating).
    public static func firstAmountMXN(
        in consequences: [GroupRule.ConsequenceEnvelope]
    ) -> Int? {
        guard let cons = consequences.first(where: { $0.type == "fine" }) else {
            return nil
        }
        if let flat = cons.config?.amount { return flat }
        if let base = cons.config?.baseAmount { return base }
        return nil
    }
}
