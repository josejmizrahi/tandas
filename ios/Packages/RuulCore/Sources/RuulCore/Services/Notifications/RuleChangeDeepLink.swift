import Foundation

/// Parses `ruul://rule/<UUID>/edit?proposedAmount=<Int>` URLs into a typed
/// destination so iOS can route to `EditRuleSheet` pre-loaded with the
/// proposed amount.
///
/// Source: APNs push payload `deep_link` field, written by
/// `finalize_vote` v3 (migration 00032) when a rule_change vote resolves
/// passed. Also reachable from inbox row tap on
/// `ActionType.ruleChangeApplyPending`.
public struct RuleChangeDeepLink: Equatable, Sendable {
    public let ruleId: UUID
    public let proposedAmount: Int

    public init?(url: URL) {
        guard url.scheme == "ruul" else { return nil }
        guard url.host == "rule" else { return nil }

        // Path: "/<UUID>/edit"
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count == 2, comps[1] == "edit" else { return nil }
        guard let ruleId = UUID(uuidString: comps[0]) else { return nil }

        let urlComps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let amountStr = urlComps?.queryItems?.first(where: { $0.name == "proposedAmount" })?.value
        guard let amountStr, let proposedAmount = Int(amountStr) else { return nil }

        self.ruleId         = ruleId
        self.proposedAmount = proposedAmount
    }

    public var userInfo: [AnyHashable: Any] {
        [
            "kind":            "ruleChangeApply",
            "rule_id":         ruleId.uuidString,
            "proposed_amount": proposedAmount,
        ]
    }
}
