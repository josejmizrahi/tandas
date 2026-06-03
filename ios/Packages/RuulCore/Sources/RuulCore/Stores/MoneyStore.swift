import Foundation
import Observation

/// F.11 — store de dinero del contexto: obligaciones abiertas, gastos,
/// multas y resultados de juego.
@MainActor
@Observable
public final class MoneyStore {
    public private(set) var obligations: [Obligation] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var contextDisplayName: String = ""
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewObligations: [Obligation],
        members: [ContextMember] = [],
        permissions: [String] = []
    ) {
        self.rpc = rpc
        self.obligations = previewObligations
        self.members = members
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var openObligations: [Obligation] { obligations.filter(\.isOpen) }
    public var settledObligations: [Obligation] { obligations.filter { !$0.isOpen } }

    /// Balance neto de un actor (positivo = le deben).
    public func balance(for actorId: UUID?) -> Double {
        guard let actorId else { return 0 }
        return openObligations.reduce(0) { sum, ob in
            if ob.creditorActorId == actorId { return sum + (ob.amount ?? 0) }
            if ob.debtorActorId == actorId { return sum - (ob.amount ?? 0) }
            return sum
        }
    }

    public func load(context: AppContext) async {
        if obligations.isEmpty { phase = .loading }
        do {
            async let obligationsTask = rpc.listObligations(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (obligationsTask, summaryTask)
            obligations = loaded
            members = summary.members
            myPermissions = summary.myPermissions
            contextDisplayName = summary.context.displayName
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func displayName(for actorId: UUID?, contextId: UUID? = nil) -> String {
        guard let actorId else { return "—" }
        if actorId == contextId { return contextDisplayName }
        return members.first { $0.actorId == actorId }?.displayName ?? contextDisplayName
    }

    public func canRecord(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("money.record")
    }

    public func canSettle(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("money.settle")
    }

    // MARK: - Acciones

    public func recordExpense(_ input: RecordExpenseInput, context: AppContext) async throws -> ExpenseResult {
        let result = try await rpc.recordExpense(input)
        await load(context: context)
        return result
    }

    public func recordFine(context: AppContext, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws {
        _ = try await rpc.recordFine(
            contextId: context.id,
            debtorActorId: debtorActorId,
            amount: amount,
            currency: currency,
            reason: reason
        )
        await load(context: context)
    }

    public func recordGameResult(_ input: RecordGameResultInput, context: AppContext) async throws -> GameResultRecorded {
        let result = try await rpc.recordGameResult(input)
        await load(context: context)
        return result
    }
}
