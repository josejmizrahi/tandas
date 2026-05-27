import Foundation

/// Foundation-scope repository for Primitivas 6/16/22 (Decision rules).
/// Reads via `group_decision_rules(...)` and writes via
/// `set_decision_rules(...)`. iOS never touches `groups.decision_rules`
/// directly.
public struct CanonicalDecisionRulesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func currentDecisionRules(groupId: UUID) async throws -> GroupDecisionRules {
        try await rpc.groupDecisionRules(groupId: groupId)
    }

    /// Trims notes before sending so the wire payload is canonical;
    /// the backend re-trims and stores null when empty.
    public func setDecisionRules(
        groupId: UUID,
        defaultStyle: DecisionStyle,
        quorumMin: Int? = nil,
        notes: String? = nil
    ) async throws -> GroupDecisionRules {
        let cleanedNotes: String? = {
            guard let notes else { return nil }
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let input = SetDecisionRulesInput(
            pGroupId: groupId,
            pDefaultStyle: defaultStyle.rawValue,
            pQuorumMin: quorumMin,
            pNotes: cleanedNotes
        )
        return try await rpc.setDecisionRules(input)
    }
}
