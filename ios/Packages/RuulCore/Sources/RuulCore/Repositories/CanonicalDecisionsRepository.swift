import Foundation

/// Foundation-scope repository for Primitiva 16 (Decisions / Voting).
/// Reads via `list_decisions_active(...)` / `list_decisions_history(...)`
/// / `decision_detail(...)`; writes via `start_vote(...)`,
/// `cast_vote(...)`, `finalize_vote(...)` and `cancel_vote(...)`.
///
/// Scheduling (`opens_at`/`closes_at`), threshold/quorum overrides and
/// reference linking (sanction/dispute/mandate/dissolution) are
/// deferred — Foundation only exposes the small set of fields the
/// propose sheet collects.
public struct CanonicalDecisionsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeDecisions(groupId: UUID) async throws -> [GroupDecisionSummary] {
        try await rpc.listDecisionsActive(groupId: groupId)
    }

    public func historyDecisions(groupId: UUID, limit: Int = 50) async throws -> [GroupDecisionSummary] {
        try await rpc.listDecisionsHistory(groupId: groupId, limit: limit)
    }

    public func detail(decisionId: UUID) async throws -> GroupDecisionDetail {
        try await rpc.decisionDetail(decisionId: decisionId)
    }

    public func propose(
        groupId: UUID,
        title: String,
        body: String?,
        decisionType: DecisionType,
        method: DecisionMethod,
        legitimacySource: LegitimacySource,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        metadata: [String: String]? = nil,
        options: [StartVoteParams.OptionDraft]?
    ) async throws -> UUID {
        let input = StartVoteParams(
            groupId: groupId,
            title: title,
            body: body?.trimmedOrNil,
            decisionType: decisionType.rawValue,
            method: method.rawValue,
            legitimacySource: legitimacySource.rawValue,
            referenceKind: referenceKind,
            referenceId: referenceId,
            options: (options?.isEmpty ?? true) ? nil : options,
            metadata: metadata
        )
        return try await rpc.startVote(input)
    }

    public func castVote(
        decisionId: UUID,
        value: VoteValue,
        optionId: UUID? = nil,
        reason: String? = nil
    ) async throws -> UUID {
        let input = CastVoteParams(
            decisionId: decisionId,
            optionId: optionId,
            voteValue: value.rawValue,
            reason: reason?.trimmedOrNil
        )
        return try await rpc.castVote(input)
    }

    public func finalize(decisionId: UUID) async throws -> String {
        try await rpc.finalizeVote(decisionId: decisionId)
    }

    public func cancel(decisionId: UUID, reason: String? = nil) async throws {
        try await rpc.cancelVote(CancelVoteParams(decisionId: decisionId, reason: reason?.trimmedOrNil))
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
