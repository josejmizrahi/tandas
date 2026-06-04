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
    /// R.2U.2: cuando true, las cargas piden `p_include_descendants=true`.
    public var includeDescendants: Bool
    /// True si el contexto tiene al menos un subcontexto activo (control de visibilidad
    /// del toggle en la UI).
    public private(set) var hasDescendants = false

    private let rpc: any RuulRPCClient
    private let pageSize: Int
    /// Para resolver "Tú" cuando el actor no está en members
    /// (contexto personal o un actor que ya salió del contexto).
    private var myActorId: UUID?

    public init(
        rpc: any RuulRPCClient,
        pageSize: Int = 50,
        myActorId: UUID? = nil,
        includeDescendants: Bool = false
    ) {
        self.rpc = rpc
        self.pageSize = pageSize
        self.myActorId = myActorId
        self.includeDescendants = includeDescendants
    }

    public init(rpc: any RuulRPCClient, previewEvents: [ActivityEvent], members: [ContextMember] = []) {
        self.rpc = rpc
        self.pageSize = 50
        self.events = previewEvents
        self.members = members
        self.phase = .loaded
        self.includeDescendants = false
    }

    public func load(context: AppContext) async {
        if events.isEmpty { phase = .loading }
        do {
            async let activityTask = rpc.listActivity(
                contextId: context.id,
                limit: pageSize,
                before: nil,
                includeDescendants: includeDescendants
            )
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            async let childrenTask = rpc.contextChildren(contextId: context.id)
            let (loaded, summary, children) = try await (activityTask, summaryTask, childrenTask)
            events = loaded
            members = summary.members
            hasMore = loaded.count >= pageSize
            hasDescendants = !children.isEmpty
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
            let more = try await rpc.listActivity(
                contextId: context.id,
                limit: pageSize,
                before: oldest,
                includeDescendants: includeDescendants
            )
            events.append(contentsOf: more)
            hasMore = more.count >= pageSize
        } catch {
            // Silencioso: la siguiente interacción reintenta.
            hasMore = false
        }
    }

    /// Cambia el flag y recarga desde 0 (se invalidan los eventos previos).
    public func setIncludeDescendants(_ value: Bool, context: AppContext) async {
        guard includeDescendants != value else { return }
        includeDescendants = value
        events = []
        hasMore = true
        await load(context: context)
    }

    public func displayName(for actorId: UUID?, contextId: UUID, contextName: String) -> String {
        guard let actorId else { return "Sistema" }
        if actorId == contextId { return contextName }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }
}
