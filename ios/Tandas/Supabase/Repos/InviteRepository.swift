import Foundation
import Supabase

enum InviteError: Error, Equatable {
    case notFound
    case expired
    case alreadyUsed
    case rpcFailed(String)
}

protocol InviteRepository: Actor {
    /// Creates a pending invite. If `phoneE164` is provided, the invite is
    /// also sent via WhatsApp (best-effort) by the live impl.
    func createInvite(groupId: UUID, phoneE164: String?) async throws -> Invite

    /// Marks an invite as consumed by the current authenticated user.
    func markUsed(inviteId: UUID) async throws -> Invite

    /// Lists pending invites for a group (admin only via RLS).
    func listPending(groupId: UUID) async throws -> [Invite]
}

// MARK: - Mock

actor MockInviteRepository: InviteRepository {
    private var _invites: [Invite] = []
    var nextCreateError: InviteError?
    var nextMarkUsedError: InviteError?

    func createInvite(groupId: UUID, phoneE164: String?) async throws -> Invite {
        if let err = nextCreateError { nextCreateError = nil; throw err }
        let invite = Invite(
            id: UUID(),
            groupId: groupId,
            invitedBy: UUID(),
            phoneE164: phoneE164,
            usedAt: nil,
            usedByUserId: nil,
            expiresAt: .now.addingTimeInterval(30 * 86_400),
            createdAt: .now
        )
        _invites.append(invite)
        return invite
    }

    func markUsed(inviteId: UUID) async throws -> Invite {
        if let err = nextMarkUsedError { nextMarkUsedError = nil; throw err }
        guard let idx = _invites.firstIndex(where: { $0.id == inviteId }) else {
            throw InviteError.notFound
        }
        let i = _invites[idx]
        if i.usedAt != nil { throw InviteError.alreadyUsed }
        if i.expiresAt < .now { throw InviteError.expired }
        let updated = Invite(
            id: i.id, groupId: i.groupId, invitedBy: i.invitedBy,
            phoneE164: i.phoneE164, usedAt: .now, usedByUserId: UUID(),
            expiresAt: i.expiresAt, createdAt: i.createdAt
        )
        _invites[idx] = updated
        return updated
    }

    func listPending(groupId: UUID) async throws -> [Invite] {
        _invites.filter { $0.groupId == groupId && $0.usedAt == nil }
    }
}

// MARK: - Live

actor LiveInviteRepository: InviteRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func createInvite(groupId: UUID, phoneE164: String?) async throws -> Invite {
        let userId = try await client.auth.session.user.id
        struct Payload: Encodable {
            let group_id: String
            let invited_by: String
            let phone_e164: String?
        }
        let payload = Payload(
            group_id: groupId.uuidString.lowercased(),
            invited_by: userId.uuidString.lowercased(),
            phone_e164: phoneE164
        )
        do {
            let invite: Invite = try await client
                .from("invites")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
            return invite
        } catch {
            throw InviteError.rpcFailed(error.localizedDescription)
        }
    }

    func markUsed(inviteId: UUID) async throws -> Invite {
        struct Params: Encodable { let p_invite_id: String }
        do {
            let invite: Invite = try await client
                .rpc("mark_invite_used", params: Params(p_invite_id: inviteId.uuidString.lowercased()))
                .execute()
                .value
            return invite
        } catch {
            throw InviteError.rpcFailed(error.localizedDescription)
        }
    }

    func listPending(groupId: UUID) async throws -> [Invite] {
        do {
            return try await client
                .from("invites")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .is("used_at", value: nil)
                .execute()
                .value
        } catch {
            throw InviteError.rpcFailed(error.localizedDescription)
        }
    }
}
