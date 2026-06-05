import Foundation
import Observation

/// R.5 — store de gobierno (governance_policies) por contexto. Read-only en
/// este slice (D.1); mutaciones se agregan en sub-slices posteriores.
@MainActor
@Observable
public final class GovernanceStore {
    public private(set) var policies: [GovernancePolicy] = []
    public private(set) var delegations: [VoteDelegation] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewPolicies: [GovernancePolicy] = [],
        previewDelegations: [VoteDelegation] = []
    ) {
        self.rpc = rpc
        self.policies = previewPolicies
        self.delegations = previewDelegations
        self.phase = .loaded
    }

    public func load(contextId: UUID) async {
        if policies.isEmpty && delegations.isEmpty { phase = .loading }
        do {
            async let policiesTask = rpc.listGovernancePolicies(contextActorId: contextId)
            async let delegationsTask = rpc.listVoteDelegations(contextActorId: contextId)
            let (p, d) = try await (policiesTask, delegationsTask)
            policies = p
            delegations = d
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Upsert (también funciona como remove cuando policyValue es `.null`).
    /// Recarga la lista al finalizar.
    public func setPolicy(contextId: UUID, key: String, value: JSONValue) async throws {
        try await rpc.setGovernancePolicy(contextActorId: contextId, policyKey: key, policyValue: value)
        await load(contextId: contextId)
    }

    /// Delegación activa donde `actorId` es el delegator, si existe.
    public func myActiveDelegation(actorId: UUID) -> VoteDelegation? {
        delegations.first { $0.delegatorActorId == actorId && $0.isActive }
    }

    /// Cuántos otros actores te delegan su voto en este contexto.
    public func incomingDelegationCount(actorId: UUID) -> Int {
        delegations.filter { $0.delegateActorId == actorId && $0.isActive }.count
    }

    public func delegateVote(contextId: UUID, to delegateActorId: UUID, endsAt: Date?) async throws {
        try await rpc.delegateVote(contextActorId: contextId, delegateActorId: delegateActorId, endsAt: endsAt)
        await load(contextId: contextId)
    }

    public func revokeMyDelegation(contextId: UUID) async throws {
        try await rpc.revokeVoteDelegation(contextActorId: contextId)
        await load(contextId: contextId)
    }

    public func reset() {
        policies = []
        delegations = []
        phase = .idle
    }
}
