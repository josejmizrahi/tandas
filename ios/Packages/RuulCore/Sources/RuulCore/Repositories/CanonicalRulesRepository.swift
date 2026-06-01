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

    /// D.22 — governance-aware archive. Routes through the executor;
    /// follows up with the underlying RPC only on `.directAllowed`.
    public func archiveRuleViaGovernance(
        groupId: UUID,
        ruleId: UUID,
        reason: String? = nil
    ) async throws -> ActionOutcome {
        let trimmed = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        var payload: [String: RPCJSONValue] = ["action": .string("archive")]
        if let trimmed { payload["reason"] = .string(trimmed) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "rule.archive",
                targetKind: "rule",
                targetId:   ruleId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            try await rpc.archiveRule(ArchiveRuleInput(pRuleId: ruleId, pReason: trimmed))
        }
        return outcome
    }

    // MARK: - Rule engine (V2-G3.1)

    /// Pulls the institutional atom catalog (`rule_shapes_catalog`).
    /// iOS caches the result for the lifetime of the store; the catalog
    /// is small + global so refetching per session is fine.
    public func listRuleShapes() async throws -> [RuleShape] {
        try await rpc.listRuleShapes()
    }

    /// Server-side dry-run. The same payload, when passed to
    /// `create_engine_rule`, will commit if and only if `valid == true`.
    public func validateRuleShape(_ shape: RuleShapePayload) async throws -> RuleShapeValidationResult {
        try await rpc.validateRuleShape(ValidateRuleShapeInput(shape: shape))
    }

    /// Atomic propose+publish for an engine rule. Server re-runs the
    /// shape validator so the iOS-side dry-run is advisory, not load-
    /// bearing.
    public func createEngineRule(
        groupId: UUID,
        title: String,
        shapeKey: String,
        condition: EngineRuleCondition?,
        consequences: [EngineRuleConsequence],
        ruleType: GroupRuleType = .norm,
        severity: Int = 1
    ) async throws -> CreateEngineRuleResult {
        let input = CreateEngineRuleInput(
            pGroupId: groupId,
            pTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            pShapeKey: shapeKey,
            pConditionTree: condition,
            pConsequences: consequences,
            pRuleType: ruleType.rawValue,
            pSeverity: severity
        )
        return try await rpc.createEngineRule(input)
    }

    public func engineRules(groupId: UUID) async throws -> [EngineRule] {
        try await rpc.groupRulesEngine(groupId: groupId)
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
