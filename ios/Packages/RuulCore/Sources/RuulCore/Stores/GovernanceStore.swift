import Foundation
import Observation

/// R.5 — store de gobierno (governance_policies) por contexto. Read-only en
/// este slice (D.1); mutaciones se agregan en sub-slices posteriores.
@MainActor
@Observable
public final class GovernanceStore {
    public private(set) var policies: [GovernancePolicy] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewPolicies: [GovernancePolicy]) {
        self.rpc = rpc
        self.policies = previewPolicies
        self.phase = .loaded
    }

    public func load(contextId: UUID) async {
        if policies.isEmpty { phase = .loading }
        do {
            policies = try await rpc.listGovernancePolicies(contextActorId: contextId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func reset() {
        policies = []
        phase = .idle
    }
}
