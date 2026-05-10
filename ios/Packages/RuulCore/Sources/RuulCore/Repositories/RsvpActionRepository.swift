import Foundation
import Supabase

public enum RsvpActionError: Error, Equatable {
    case rpcFailed(String)
}

/// Reads/writes for `public.rsvp_actions` (atom log).
///
/// Append-only. The latest row per (resource, member) is the projected
/// "current RSVP status" — derive that on read or via a server view.
public protocol RsvpActionRepository: Actor {
    func listForResource(_ resourceId: UUID) async throws -> [RsvpAction]
    func listForMember(_ memberId: UUID, limit: Int) async throws -> [RsvpAction]
    func record(_ action: RsvpAction) async throws -> RsvpAction
}

// MARK: - Mock

public actor MockRsvpActionRepository: RsvpActionRepository {
    private var actions: [RsvpAction]

    public init(seed: [RsvpAction] = []) { self.actions = seed }

    public func listForResource(_ resourceId: UUID) async throws -> [RsvpAction] {
        actions.filter { $0.resourceId == resourceId }.sorted { $0.recordedAt > $1.recordedAt }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 50) async throws -> [RsvpAction] {
        actions.filter { $0.memberId == memberId }
            .sorted { $0.recordedAt > $1.recordedAt }.prefix(limit).map { $0 }
    }

    public func record(_ action: RsvpAction) async throws -> RsvpAction {
        actions.append(action)
        return action
    }
}

// MARK: - Live

public actor LiveRsvpActionRepository: RsvpActionRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listForResource(_ resourceId: UUID) async throws -> [RsvpAction] {
        do {
            return try await client
                .from("rsvp_actions")
                .select("*")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .order("recorded_at", ascending: false)
                .execute()
                .value
        } catch {
            throw RsvpActionError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 50) async throws -> [RsvpAction] {
        do {
            return try await client
                .from("rsvp_actions")
                .select("*")
                .eq("member_id", value: memberId.uuidString.lowercased())
                .order("recorded_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw RsvpActionError.rpcFailed(error.localizedDescription)
        }
    }

    public func record(_ action: RsvpAction) async throws -> RsvpAction {
        do {
            return try await client
                .from("rsvp_actions")
                .insert(action)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw RsvpActionError.rpcFailed(error.localizedDescription)
        }
    }
}
