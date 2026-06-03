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
}
