import Foundation
import Observation

/// P1.9 — store del browser de ledger: lista `money_transactions` del contexto
/// (lectura) + acción admin `void_transaction`. Read-mostly; gateado por
/// `money.settle` (o ser el creador de la transacción).
@MainActor
@Observable
public final class LedgerStore {
    public private(set) var transactions: [MoneyTransaction] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var contextDisplayName: String = ""
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient
    /// Para resolver "Tú" y para gatear el void del creador.
    private var myActorId: UUID?

    public init(rpc: any RuulRPCClient, myActorId: UUID? = nil) {
        self.rpc = rpc
        self.myActorId = myActorId
    }

    public init(
        rpc: any RuulRPCClient,
        previewTransactions: [MoneyTransaction],
        members: [ContextMember] = [],
        permissions: [String] = [],
        myActorId: UUID? = nil
    ) {
        self.rpc = rpc
        self.transactions = previewTransactions
        self.members = members
        self.myPermissions = permissions
        self.myActorId = myActorId
        self.phase = .loaded
    }

    public var posted: [MoneyTransaction] { transactions.filter(\.isPosted) }
    public var voided: [MoneyTransaction] { transactions.filter(\.isVoided) }

    public func load(context: AppContext) async {
        if transactions.isEmpty { phase = .loading }
        // Cargas independientes — un RPC roto no debe borrar el otro (mismo
        // criterio que MoneyStore: el summary es opcional, el ledger es lo central).
        var summaryLoaded = false
        do {
            let summary = try await rpc.contextSummary(contextId: context.id)
            members = summary.members
            myPermissions = summary.myPermissions
            contextDisplayName = summary.context.displayName
            summaryLoaded = true
        } catch {
            // Non-fatal.
        }
        do {
            transactions = try await rpc.listContextTransactions(contextId: context.id)
        } catch {
            if !summaryLoaded {
                phase = .failed(message: UserFacingError.from(error).message)
                return
            }
        }
        phase = .loaded
    }

    public func displayName(for actorId: UUID?, contextId: UUID? = nil) -> String {
        guard let actorId else { return "—" }
        if actorId == contextId { return contextDisplayName.isEmpty ? "El contexto" : contextDisplayName }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }

    /// ¿Puede anular esta transacción? Backend: creador o `money.settle`. Sólo
    /// `posted` y nunca settlement (se revierten por el handshake).
    public func canVoid(_ txn: MoneyTransaction, in context: AppContext) -> Bool {
        guard txn.isPosted, !txn.isSettlement else { return false }
        if context.isPersonal { return true }
        if let myActorId, txn.createdByActorId == myActorId { return true }
        return myPermissions.contains("money.settle")
    }

    @discardableResult
    public func void(_ txn: MoneyTransaction, reason: String?, context: AppContext) async throws -> TransactionVoided {
        let result = try await rpc.voidTransaction(transactionId: txn.id, reason: reason)
        await load(context: context)
        return result
    }
}
