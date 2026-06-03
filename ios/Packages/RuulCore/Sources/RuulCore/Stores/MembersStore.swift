import Foundation
import Observation

/// F.5 — store de membresía de un contexto. Los miembros y permisos del
/// caller salen de `context_summary()`; las mutaciones son RPCs dedicados.
@MainActor
@Observable
public final class MembersStore {
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewMembers: [ContextMember], permissions: [String] = []) {
        self.rpc = rpc
        self.members = previewMembers
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if members.isEmpty { phase = .loading }
        do {
            let summary = try await rpc.contextSummary(contextId: context.id)
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func canManageMembers(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("members.manage")
    }

    public func canInvite(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("context.invite")
    }

    // MARK: - Mutaciones

    public func createInvite(contextId: UUID, maxUses: Int? = nil, expiresAt: Date? = nil) async throws -> InviteCreated {
        try await rpc.createInvite(contextId: contextId, maxUses: maxUses, expiresAt: expiresAt)
    }

    /// Invitación directa actor→actor. Tras el éxito refresca el contexto para
    /// que el invitado aparezca en la lista (status='invited').
    public func inviteMember(
        context: AppContext,
        memberActorId: UUID,
        membershipType: String = "member"
    ) async throws -> InviteMemberResult {
        let result = try await rpc.inviteMember(
            contextId: context.id,
            memberActorId: memberActorId,
            membershipType: membershipType
        )
        await load(context: context)
        return result
    }

    public func removeMember(context: AppContext, memberActorId: UUID, reason: String?) async throws {
        try await rpc.removeMember(contextId: context.id, memberActorId: memberActorId, reason: reason)
        await load(context: context)
    }

    public func assignRole(context: AppContext, memberActorId: UUID, roleKey: String) async throws {
        try await rpc.assignRole(contextId: context.id, memberActorId: memberActorId, roleKey: roleKey)
        await load(context: context)
    }

    public func leave(contextId: UUID) async throws {
        try await rpc.leaveContext(contextId: contextId)
    }

    /// Carga miembros únicos de TODOS los contextos colectivos del actor (excepto
    /// el actual y excepto el actor actual), para usarlos como candidatos en una
    /// invitación directa por `invite_member`. Excluye miembros ya activos del
    /// contexto actual. Pondera por "compartimos N contextos" para ordenar.
    ///
    /// El backend no expone búsqueda de actores — el set conocido del usuario
    /// son las personas con las que ya comparte algún contexto.
    public func loadKnownActors(
        myWorld: MyWorld,
        excludingContext currentContextId: UUID,
        myActorId: UUID?
    ) async -> [KnownActor] {
        let otherContexts = myWorld.contexts.filter { $0.contextActorId != currentContextId }
        guard !otherContexts.isEmpty else { return [] }

        let summaries = await withTaskGroup(of: ContextSummary?.self, returning: [ContextSummary].self) { group in
            for context in otherContexts {
                let id = context.contextActorId
                group.addTask { [rpc] in
                    try? await rpc.contextSummary(contextId: id)
                }
            }
            var out: [ContextSummary] = []
            for await summary in group {
                if let summary { out.append(summary) }
            }
            return out
        }

        let alreadyInCurrent = Set(members.map(\.actorId))
        var byActor: [UUID: KnownActor] = [:]
        for summary in summaries {
            for member in summary.members where member.actorId != myActorId && !alreadyInCurrent.contains(member.actorId) {
                if var existing = byActor[member.actorId] {
                    existing.sharedContexts.append(summary.context.displayName)
                    byActor[member.actorId] = existing
                } else {
                    byActor[member.actorId] = KnownActor(
                        actorId: member.actorId,
                        displayName: member.displayName,
                        sharedContexts: [summary.context.displayName]
                    )
                }
            }
        }
        return byActor.values.sorted { lhs, rhs in
            if lhs.sharedContexts.count != rhs.sharedContexts.count {
                return lhs.sharedContexts.count > rhs.sharedContexts.count
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

/// Actor conocido del usuario para flujos de invitación directa (`invite_member`).
public struct KnownActor: Sendable, Equatable, Identifiable {
    public let actorId: UUID
    public let displayName: String
    /// Nombres de contextos donde compartes membresía con esta persona.
    public var sharedContexts: [String]

    public var id: UUID { actorId }

    public init(actorId: UUID, displayName: String, sharedContexts: [String]) {
        self.actorId = actorId
        self.displayName = displayName
        self.sharedContexts = sharedContexts
    }
}
