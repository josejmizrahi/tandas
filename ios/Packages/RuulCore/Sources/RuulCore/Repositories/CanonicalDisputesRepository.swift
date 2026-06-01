import Foundation

/// Foundation-scope repository for Primitiva 14 (Disputas). Reads via
/// `group_disputes_active(...)` + `dispute_detail(...)` +
/// `list_dispute_events(...)`. Writes via `dispute_sanction(...)`,
/// `open_dispute(...)`, `append_dispute_event(...)`,
/// `record_dispute_resolution(...)` and `escalate_dispute_to_vote(...)`.
public struct CanonicalDisputesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    // MARK: - Reads

    public func activeDisputes(groupId: UUID, limit: Int = 50) async throws -> [GroupDispute] {
        try await rpc.groupDisputesActive(groupId: groupId, limit: limit)
    }

    public func detail(disputeId: UUID) async throws -> GroupDisputeDetail {
        try await rpc.disputeDetail(disputeId: disputeId)
    }

    public func events(disputeId: UUID, limit: Int = 200) async throws -> [GroupDisputeEvent] {
        try await rpc.listDisputeEvents(disputeId: disputeId, limit: limit)
    }

    // MARK: - Writes

    /// Opens a dispute against an existing sanction. Trims summary
    /// before sending; backend re-trims defensively.
    public func disputeSanction(sanctionId: UUID, summary: String) async throws -> UUID {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = DisputeSanctionInput(pSanctionId: sanctionId, pSummary: trimmed)
        return try await rpc.disputeSanction(input)
    }

    /// Opens a generic dispute. Title is required; description and
    /// respondent are optional.
    public func openDispute(
        groupId: UUID,
        subjectKind: DisputeSubjectKind,
        subjectId: UUID?,
        title: String,
        description: String?,
        respondentMembershipId: UUID?
    ) async throws -> UUID {
        let input = OpenDisputeInput(
            groupId: groupId,
            subjectKind: subjectKind.rawValue,
            subjectId: subjectId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description?.trimmedOrNil,
            respondentMembershipId: respondentMembershipId
        )
        return try await rpc.openDispute(input)
    }

    /// Appends an event (comment / evidence / mediation note / other)
    /// to a dispute's append-only timeline.
    public func appendEvent(
        disputeId: UUID,
        eventType: DisputeEventType,
        body: String?
    ) async throws -> UUID {
        let input = AppendDisputeEventInput(
            disputeId: disputeId,
            eventType: eventType.rawValue,
            body: body?.trimmedOrNil
        )
        return try await rpc.appendDisputeEvent(input)
    }

    /// Records the resolution + closes the dispute.
    public func recordResolution(
        disputeId: UUID,
        method: DisputeResolutionMethod,
        resolutionText: String
    ) async throws {
        let input = RecordDisputeResolutionInput(
            disputeId: disputeId,
            method: method.rawValue,
            resolutionText: resolutionText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try await rpc.recordDisputeResolution(input)
    }

    /// D24P10B — governance-aware resolution. Resolver decide direct/decision.
    public func recordResolutionViaGovernance(
        groupId: UUID,
        disputeId: UUID,
        method: DisputeResolutionMethod,
        resolutionText: String
    ) async throws -> ActionOutcome {
        let cleanedText = resolutionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: RPCJSONValue] = [
            "dispute_id":      .string(disputeId.uuidString),
            "method":          .string(method.rawValue),
            "resolution_text": .string(cleanedText)
        ]
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "dispute.resolve",
                targetKind: "dispute",
                targetId:   disputeId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            try await recordResolution(disputeId: disputeId, method: method, resolutionText: cleanedText)
        }
        return outcome
    }

    /// Escalates the dispute to a new linked vote. Returns the new
    /// decision id so the caller can navigate straight to it.
    public func escalateToVote(
        disputeId: UUID,
        decisionTitle: String,
        decisionMethod: DecisionMethod = .majority,
        closesAt: Date? = nil
    ) async throws -> UUID {
        let input = EscalateDisputeToVoteInput(
            disputeId: disputeId,
            decisionTitle: decisionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            decisionMethod: decisionMethod.rawValue,
            closesAt: closesAt
        )
        return try await rpc.escalateDisputeToVote(input)
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
