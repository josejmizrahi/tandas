import Foundation
import Observation

/// F.13 — store del log de actividad del contexto (paginado con `before`).
@MainActor
@Observable
public final class ActivityStore {
    public private(set) var events: [ActivityEvent] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = true

    private let rpc: any RuulRPCClient
    private let pageSize: Int

    public init(rpc: any RuulRPCClient, pageSize: Int = 50) {
        self.rpc = rpc
        self.pageSize = pageSize
    }

    public init(rpc: any RuulRPCClient, previewEvents: [ActivityEvent], members: [ContextMember] = []) {
        self.rpc = rpc
        self.pageSize = 50
        self.events = previewEvents
        self.members = members
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if events.isEmpty { phase = .loading }
        do {
            async let activityTask = rpc.listActivity(contextId: context.id, limit: pageSize, before: nil)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (activityTask, summaryTask)
            events = loaded
            members = summary.members
            hasMore = loaded.count >= pageSize
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Paginación: carga la siguiente página (eventos anteriores al último).
    public func loadMore(context: AppContext) async {
        guard hasMore, !isLoadingMore, let oldest = events.last?.occurredAt else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await rpc.listActivity(contextId: context.id, limit: pageSize, before: oldest)
            events.append(contentsOf: more)
            hasMore = more.count >= pageSize
        } catch {
            // Silencioso: la siguiente interacción reintenta.
            hasMore = false
        }
    }

    public func displayName(for actorId: UUID?, contextId: UUID, contextName: String) -> String {
        guard let actorId else { return "Sistema" }
        if actorId == contextId { return contextName }
        return members.first { $0.actorId == actorId }?.displayName ?? "Alguien"
    }
}
