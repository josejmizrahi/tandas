import Foundation

/// Foundation-scope repository for Primitiva 4 (Rules). Reads via
/// `group_rules_active(...)` and writes via `create_text_rule(...)`
/// + the pre-existing `archive_rule(...)` RPC. iOS never touches
/// `group_rules` / `group_rule_versions` directly.
public struct CanonicalRulesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeRules(groupId: UUID) async throws -> [GroupRule] {
        try await rpc.groupRulesActive(groupId: groupId)
    }

    /// Trims title/body before sending; backend re-trims and raises
    /// `rule title/body required` if empty.
    public func createTextRule(
        groupId: UUID,
        title: String,
        body: String,
        ruleType: GroupRuleType = .norm,
        severity: Int = 1
    ) async throws -> CreateTextRuleResult {
        let input = CreateTextRuleInput(
            pGroupId: groupId,
            pTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            pBody: body.trimmingCharacters(in: .whitespacesAndNewlines),
            pRuleType: ruleType.rawValue,
            pSeverity: severity
        )
        return try await rpc.createTextRule(input)
    }

    public func archiveRule(ruleId: UUID, reason: String? = nil) async throws {
        let trimmed = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        try await rpc.archiveRule(ArchiveRuleInput(pRuleId: ruleId, pReason: trimmed))
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
