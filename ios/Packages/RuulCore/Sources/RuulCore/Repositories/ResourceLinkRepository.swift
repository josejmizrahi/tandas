import Foundation
import Supabase

/// Read + write gateway for `public.resource_links` (mig 00198).
///
/// Wraps two SECURITY DEFINER RPCs:
///   - `link_resource_to_event(p_event_id, p_resource_id)`
///   - `unlink_resource_from_event(p_link_id)`
///
/// Reads go directly to the table via RLS (member-only SELECT). Writes
/// always flow through the RPCs — direct INSERT/UPDATE is not permitted.
public protocol ResourceLinkRepository: Actor {
    /// Returns the active `uses` links for an event. Each row's
    /// `toResourceId` points at a space/asset/fund/right the event uses.
    /// Sorted by `linkedAt` desc.
    func listActiveUses(for eventId: UUID) async throws -> [ResourceLink]

    /// Attaches a target resource to an event with `link_kind=uses`.
    /// Idempotent: returns the existing link id if one is already active.
    /// Server validates that the source is `resource_type=event`, target
    /// is in (space, asset, fund, right), and both belong to the same group.
    func link(event eventId: UUID, uses resourceId: UUID) async throws -> UUID

    /// Stamps `unlinked_at` on a link row. Idempotent: a no-op if already
    /// unlinked. Server emits a `resourceUnlinked` atom on transition.
    func unlink(_ linkId: UUID) async throws
}

public enum ResourceLinkError: LocalizedError, Sendable, Equatable {
    /// RLS, missing membership, or unauthenticated caller.
    case permissionDenied(String)
    /// Link / event / target resource not found.
    case notFound(String)
    /// Server-side validation rejected the call (wrong types, cross-group, etc.).
    case invalidState(String)
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let m): return "Permiso denegado: \(m)"
        case .notFound(let m):         return "No encontrado: \(m)"
        case .invalidState(let m):     return "Estado inválido: \(m)"
        case .rpcFailed(let m):        return "Error: \(m)"
        }
    }
}

// MARK: - Mock

public actor MockResourceLinkRepository: ResourceLinkRepository {
    public private(set) var links: [ResourceLink]
    public var nextError: ResourceLinkError?

    public init(seed: [ResourceLink] = []) {
        self.links = seed
    }

    public func listActiveUses(for eventId: UUID) async throws -> [ResourceLink] {
        if let err = nextError { nextError = nil; throw err }
        return links
            .filter { $0.fromResourceId == eventId && $0.linkKind == .uses && $0.isActive }
            .sorted { $0.linkedAt > $1.linkedAt }
    }

    public func link(event eventId: UUID, uses resourceId: UUID) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        if let existing = links.first(where: {
            $0.fromResourceId == eventId
            && $0.toResourceId == resourceId
            && $0.linkKind == .uses
            && $0.isActive
        }) {
            return existing.id
        }
        let groupId = links.first(where: { $0.fromResourceId == eventId })?.groupId ?? UUID()
        let link = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: eventId,
            toResourceId: resourceId,
            linkKind: .uses,
            linkedAt: Date()
        )
        links.append(link)
        return link.id
    }

    public func unlink(_ linkId: UUID) async throws {
        if let err = nextError { nextError = nil; throw err }
        guard let idx = links.firstIndex(where: { $0.id == linkId }) else { return }
        let row = links[idx]
        if !row.isActive { return }
        links[idx] = ResourceLink(
            id: row.id,
            groupId: row.groupId,
            fromResourceId: row.fromResourceId,
            toResourceId: row.toResourceId,
            linkKind: row.linkKind,
            linkedAt: row.linkedAt,
            linkedBy: row.linkedBy,
            unlinkedAt: Date(),
            unlinkedBy: nil
        )
    }

    /// Test helper.
    public func seed(_ link: ResourceLink) {
        links.append(link)
    }
}

// MARK: - Live

public actor LiveResourceLinkRepository: ResourceLinkRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func listActiveUses(for eventId: UUID) async throws -> [ResourceLink] {
        do {
            return try await client
                .from("resource_links")
                .select("*")
                .eq("from_resource_id", value: eventId.uuidString.lowercased())
                .eq("link_kind", value: "uses")
                .is("unlinked_at", value: nil)
                .order("linked_at", ascending: false)
                .execute()
                .value
        } catch {
            throw mapError(error, default: "list resource_links failed")
        }
    }

    public func link(event eventId: UUID, uses resourceId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_event_id: String
            let p_resource_id: String
        }
        let params = Params(
            p_event_id: eventId.uuidString.lowercased(),
            p_resource_id: resourceId.uuidString.lowercased()
        )
        do {
            let id: UUID = try await client.rpc("link_resource_to_event", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "link_resource_to_event failed")
        }
    }

    public func unlink(_ linkId: UUID) async throws {
        struct Params: Encodable { let p_link_id: String }
        let params = Params(p_link_id: linkId.uuidString.lowercased())
        do {
            _ = try await client.rpc("unlink_resource_from_event", params: params).execute()
        } catch {
            throw mapError(error, default: "unlink_resource_from_event failed")
        }
    }

    private func mapError(_ error: Error, default defaultMsg: String) -> ResourceLinkError {
        let msg = (error as NSError).localizedDescription
        if msg.contains("authentication required")
            || msg.contains("not a member")            { return .permissionDenied(msg) }
        if msg.contains("not found") || msg.contains("archived") { return .notFound(msg) }
        if msg.contains("must be of resource_type")
            || msg.contains("same group")
            || msg.contains("can only use")            { return .invalidState(msg) }
        return .rpcFailed("\(defaultMsg): \(msg)")
    }
}
