import Foundation
import OSLog
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
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "invites")
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
        let invite: Invite
        do {
            invite = try await client
                .from("invites")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw InviteError.rpcFailed(error.localizedDescription)
        }

        if let phone = phoneE164, !phone.isEmpty {
            await sendWhatsAppBestEffort(inviteId: invite.id, phone: phone, groupId: groupId)
        }
        return invite
    }

    /// Best-effort WhatsApp send via the `send-whatsapp-invite` edge function.
    /// Failures (Wassenger unconfigured, network, etc.) are swallowed — the
    /// invite row exists; recipient can be re-invited if the message never
    /// arrives.
    private func sendWhatsAppBestEffort(inviteId: UUID, phone: String, groupId: UUID) async {
        do {
            struct GroupInfo: Decodable {
                let name: String
                let invite_code: String
            }
            let info: GroupInfo = try await client
                .from("groups")
                .select("name, invite_code")
                .eq("id", value: groupId.uuidString.lowercased())
                .single()
                .execute()
                .value

            struct Body: Encodable {
                let invite_id: String
                let phone: String
                let group_name: String
                let invite_code: String
            }
            _ = try await client.functions.invoke(
                "send-whatsapp-invite",
                options: FunctionInvokeOptions(body: Body(
                    invite_id: inviteId.uuidString.lowercased(),
                    phone: phone,
                    group_name: info.name,
                    invite_code: info.invite_code
                ))
            ) as WhatsAppInviteResponse
        } catch {
            log.warning("WhatsApp invite send failed (best-effort): \(error.localizedDescription, privacy: .public)")
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

private struct WhatsAppInviteResponse: Decodable {
    let sent: Bool?
    let reason: String?
}
