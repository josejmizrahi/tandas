import Foundation
import Observation

/// F.12 — store de settlement: generar batch, ver items y marcar pagos.
@MainActor
@Observable
public final class SettlementStore {
    public private(set) var batches: [SettlementBatch] = []
    public private(set) var itemsByBatch: [UUID: [SettlementItem]] = [:]
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle
    /// Resultado del último generate (para informar "todo neteó a cero").
    public private(set) var lastGenerateResult: SettlementBatchResult?

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewBatches: [SettlementBatch],
        items: [UUID: [SettlementItem]] = [:],
        members: [ContextMember] = [],
        permissions: [String] = []
    ) {
        self.rpc = rpc
        self.batches = previewBatches
        self.itemsByBatch = items
        self.members = members
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if batches.isEmpty { phase = .loading }
        do {
            async let batchesTask = rpc.listSettlementBatches(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loadedBatches, summary) = try await (batchesTask, summaryTask)
            batches = loadedBatches
            members = summary.members
            myPermissions = summary.myPermissions

            // Cargar items de cada batch (pocos batches por contexto).
            var loadedItems: [UUID: [SettlementItem]] = [:]
            for batch in loadedBatches {
                loadedItems[batch.id] = try await rpc.listSettlementItems(batchId: batch.id)
            }
            itemsByBatch = loadedItems
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        return members.first { $0.actorId == actorId }?.displayName ?? "Alguien"
    }

    public func items(for batchId: UUID) -> [SettlementItem] {
        itemsByBatch[batchId] ?? []
    }

    public func canSettle(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("money.settle")
    }

    // MARK: - Acciones

    public func generate(context: AppContext, currency: String) async throws -> SettlementBatchResult {
        let result = try await rpc.generateSettlementBatch(contextId: context.id, currency: currency)
        lastGenerateResult = result
        await load(context: context)
        return result
    }

    public func markPaid(itemId: UUID, context: AppContext, myActorId: UUID?) async throws -> MarkPaidResult {
        let result = try await rpc.markSettlementPaid(itemId: itemId)
        await load(context: context)
        return result
    }

    /// ¿Este item lo puede marcar como pagado el usuario actual?
    /// (es quien paga, o tiene money.settle)
    public func canMarkPaid(_ item: SettlementItem, context: AppContext, myActorId: UUID?) -> Bool {
        guard !item.isPaid else { return false }
        return item.fromActorId == myActorId || canSettle(in: context)
    }
}
