import Foundation

/// Foundation-scope repository for Primitiva 20 (Culture). Reads via
/// `group_cultural_norms_active(...)`; writes via `propose_cultural_norm`,
/// `endorse_cultural_norm`, `retire_cultural_norm`.
public struct CanonicalCulturalNormsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeNorms(groupId: UUID) async throws -> [GroupCulturalNorm] {
        try await rpc.groupCulturalNormsActive(groupId: groupId)
    }

    public func proposeNorm(
        groupId: UUID,
        type: CulturalNormType,
        title: String,
        body: String?,
        visibility: CulturalNormVisibility = .members
    ) async throws -> UUID {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let input = ProposeCulturalNormParams(
            groupId: groupId,
            normType: type.rawValue,
            title: trimmedTitle,
            body: trimmedBody,
            visibility: visibility.rawValue
        )
        return try await rpc.proposeCulturalNorm(input)
    }

    @discardableResult
    public func endorse(normId: UUID) async throws -> Int {
        try await rpc.endorseCulturalNorm(normId: normId)
    }

    public func retire(normId: UUID, reason: String? = nil) async throws {
        let trimmed = reason.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        try await rpc.retireCulturalNorm(RetireCulturalNormParams(normId: normId, reason: trimmed))
    }
}
