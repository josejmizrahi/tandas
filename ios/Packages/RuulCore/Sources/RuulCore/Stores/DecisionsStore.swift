import Foundation
import Observation

/// F.10 — store de decisiones del contexto.
@MainActor
@Observable
public final class DecisionsStore {
    public private(set) var decisions: [Decision] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewDecisions: [Decision], members: [ContextMember] = [], permissions: [String] = []) {
        self.rpc = rpc
        self.decisions = previewDecisions
        self.members = members
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var open: [Decision] { decisions.filter(\.isOpen) }
    public var closed: [Decision] { decisions.filter { !$0.isOpen } }

    public func load(context: AppContext) async {
        if decisions.isEmpty { phase = .loading }
        do {
            async let decisionsTask = rpc.listDecisions(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (decisionsTask, summaryTask)
            decisions = loaded
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        return members.first { $0.actorId == actorId }?.displayName ?? "Alguien"
    }

    public func canCreate(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.create")
    }

    public func canVote(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.vote")
    }

    public func canExecute(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.execute")
    }

    // MARK: - Acciones

    public func createDecision(_ input: CreateDecisionInput, context: AppContext) async throws -> Decision {
        let decision = try await rpc.createDecision(input)
        await load(context: context)
        return decision
    }
}

/// F.10 — store del detalle de una decisión: decisión + votos.
@MainActor
@Observable
public final class DecisionDetailStore {
    public private(set) var decision: Decision?
    public private(set) var votes: [DecisionVote] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle
    /// Resultado de la última acción de voto/cierre.
    public private(set) var lastResult: VoteResult?

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func load(decisionId: UUID, context: AppContext) async {
        if decision == nil { phase = .loading }
        do {
            async let decisionsTask = rpc.listDecisions(contextId: context.id)
            async let votesTask = rpc.listDecisionVotes(decisionId: decisionId)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (decisions, loadedVotes, summary) = try await (decisionsTask, votesTask, summaryTask)
            decision = decisions.first { $0.id == decisionId }
            votes = loadedVotes
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        return members.first { $0.actorId == actorId }?.displayName ?? "Alguien"
    }

    public func myVote(myActorId: UUID?) -> DecisionVote? {
        guard let myActorId else { return nil }
        return votes.first { $0.voterActorId == myActorId }
    }

    public func canVote(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.vote")
    }

    public func canExecute(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("decisions.execute")
    }

    // MARK: - Acciones

    public func vote(_ choice: VoteChoice, decisionId: UUID, context: AppContext) async throws -> VoteResult {
        let result = try await rpc.voteDecision(decisionId: decisionId, vote: choice, option: nil)
        lastResult = result
        await load(decisionId: decisionId, context: context)
        return result
    }

    public func close(decisionId: UUID, context: AppContext) async throws -> VoteResult {
        let result = try await rpc.closeDecision(decisionId: decisionId)
        lastResult = result
        await load(decisionId: decisionId, context: context)
        return result
    }

    public func execute(decisionId: UUID, context: AppContext) async throws {
        try await rpc.executeDecision(decisionId: decisionId, result: nil)
        await load(decisionId: decisionId, context: context)
    }
}
