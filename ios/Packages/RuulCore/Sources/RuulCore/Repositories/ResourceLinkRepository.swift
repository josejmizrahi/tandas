import Foundation
import Supabase

/// Read + write gateway for `public.resource_links` (mig 00198 + mig 00267).
///
/// Wraps the polymorphic RPCs:
///   - `link_resources(p_from_resource_id, p_to_resource_id, p_link_kind)`
///   - `unlink_resources(p_from_resource_id, p_to_resource_id, p_link_kind)`
///   - Legacy `link_resource_to_event` / `unlink_resource_from_event`
///     remain available server-side as thin wrappers; the iOS layer
///     consumes them only via the deprecated `link(event:uses:)`
///     methods kept for backward compat with pre-Fase 2 callers.
///
/// Reads go directly to the table via RLS (member-only SELECT). Writes
/// always flow through the RPCs — direct INSERT/UPDATE is not permitted.
public protocol ResourceLinkRepository: Actor {
    // MARK: - Polymorphic (Fase 2)

    /// Creates a link `from → to` with the given `kind`. Idempotent —
    /// returns the existing active link id when the tuple already
    /// matches. Server validates `(from_type, to_type, kind)` against
    /// the `resource_link_kinds` catalog.
    func link(from: UUID, to: UUID, kind: LinkKind) async throws -> UUID

    /// Marks `from → to (kind)` as unlinked. Admin-only on the server.
    /// Idempotent — silent no-op when no active link matches.
    func unlink(from: UUID, to: UUID, kind: LinkKind) async throws

    /// Active links involving `resource`. Splits incoming (where
    /// `to_resource_id = resource`) from outgoing (`from_resource_id =
    /// resource`) so the UI can render two sub-sections without
    /// reshuffling.
    func linksFor(resource: UUID) async throws -> (incoming: [ResourceLink], outgoing: [ResourceLink])

    // MARK: - Legacy (pre-Fase 2; event-only)

    /// Returns the active `uses` links for an event. Each row's
    /// `toResourceId` points at a space/asset/fund/right the event uses.
    /// Sorted by `linkedAt` desc.
    func listActiveUses(for eventId: UUID) async throws -> [ResourceLink]

    /// Attaches a target resource to an event with `link_kind=uses`.
    /// Idempotent: returns the existing link id if one is already active.
    func link(event eventId: UUID, uses resourceId: UUID) async throws -> UUID

    /// Stamps `unlinked_at` on a link row by id. Idempotent: a no-op if
    /// already unlinked.
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

    // MARK: - Polymorphic

    public func link(from: UUID, to: UUID, kind: LinkKind) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        if let existing = links.first(where: {
            $0.fromResourceId == from && $0.toResourceId == to
            && $0.linkKind == kind && $0.isActive
        }) {
            return existing.id
        }
        let groupId = links.first(where: { $0.fromResourceId == from })?.groupId ?? UUID()
        let row = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: from,
            toResourceId: to,
            linkKind: kind,
            linkedAt: Date()
        )
        links.append(row)
        return row.id
    }

    public func unlink(from: UUID, to: UUID, kind: LinkKind) async throws {
        if let err = nextError { nextError = nil; throw err }
        guard let idx = links.firstIndex(where: {
            $0.fromResourceId == from && $0.toResourceId == to
            && $0.linkKind == kind && $0.isActive
        }) else { return }
        let row = links[idx]
        links[idx] = ResourceLink(
            id: row.id, groupId: row.groupId,
            fromResourceId: row.fromResourceId, toResourceId: row.toResourceId,
            linkKind: row.linkKind, linkedAt: row.linkedAt, linkedBy: row.linkedBy,
            unlinkedAt: Date(), unlinkedBy: nil
        )
    }

    public func linksFor(resource: UUID) async throws -> (incoming: [ResourceLink], outgoing: [ResourceLink]) {
        if let err = nextError { nextError = nil; throw err }
        let active = links.filter { $0.isActive }
        let incoming = active.filter { $0.toResourceId == resource }
            .sorted { $0.linkedAt > $1.linkedAt }
        let outgoing = active.filter { $0.fromResourceId == resource }
            .sorted { $0.linkedAt > $1.linkedAt }
        return (incoming, outgoing)
    }

    // MARK: - Legacy

    public func listActiveUses(for eventId: UUID) async throws -> [ResourceLink] {
        if let err = nextError { nextError = nil; throw err }
        return links
            .filter { $0.fromResourceId == eventId && $0.linkKind == .uses && $0.isActive }
            .sorted { $0.linkedAt > $1.linkedAt }
    }

    public func link(event eventId: UUID, uses resourceId: UUID) async throws -> UUID {
        try await link(from: eventId, to: resourceId, kind: .uses)
    }

    public func unlink(_ linkId: UUID) async throws {
        if let err = nextError { nextError = nil; throw err }
        guard let idx = links.firstIndex(where: { $0.id == linkId }) else { return }
        let row = links[idx]
        if !row.isActive { return }
        links[idx] = ResourceLink(
            id: row.id, groupId: row.groupId,
            fromResourceId: row.fromResourceId, toResourceId: row.toResourceId,
            linkKind: row.linkKind, linkedAt: row.linkedAt, linkedBy: row.linkedBy,
            unlinkedAt: Date(), unlinkedBy: nil
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

    // MARK: - Polymorphic (Fase 2)

    public func link(from: UUID, to: UUID, kind: LinkKind) async throws -> UUID {
        struct Params: Encodable {
            let p_from_resource_id: String
            let p_to_resource_id:   String
            let p_link_kind:        String
        }
        let params = Params(
            p_from_resource_id: from.uuidString.lowercased(),
            p_to_resource_id:   to.uuidString.lowercased(),
            p_link_kind:        kind.rawValue
        )
        do {
            return try await client.rpc("link_resources", params: params).execute().value
        } catch {
            throw mapError(error, default: "link_resources failed")
        }
    }

    public func unlink(from: UUID, to: UUID, kind: LinkKind) async throws {
        struct Params: Encodable {
            let p_from_resource_id: String
            let p_to_resource_id:   String
            let p_link_kind:        String
        }
        let params = Params(
            p_from_resource_id: from.uuidString.lowercased(),
            p_to_resource_id:   to.uuidString.lowercased(),
            p_link_kind:        kind.rawValue
        )
        do {
            _ = try await client.rpc("unlink_resources", params: params).execute()
        } catch {
            throw mapError(error, default: "unlink_resources failed")
        }
    }

    public func linksFor(resource: UUID) async throws -> (incoming: [ResourceLink], outgoing: [ResourceLink]) {
        let id = resource.uuidString.lowercased()
        do {
            // Two parallel fetches keep the projection cheap: the
            // resource_links table is indexed on both directions.
            async let outgoing: [ResourceLink] = client
                .from("resource_links")
                .select("*")
                .eq("from_resource_id", value: id)
                .is("unlinked_at", value: nil)
                .order("linked_at", ascending: false)
                .execute()
                .value
            async let incoming: [ResourceLink] = client
                .from("resource_links")
                .select("*")
                .eq("to_resource_id", value: id)
                .is("unlinked_at", value: nil)
                .order("linked_at", ascending: false)
                .execute()
                .value
            let (out, inc) = try await (outgoing, incoming)
            return (incoming: inc, outgoing: out)
        } catch {
            throw mapError(error, default: "linksFor(resource:) failed")
        }
    }

    // MARK: - Legacy (pre-Fase 2)

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
        // Routes through the polymorphic RPC under the hood; the
        // legacy entry stays around for pre-Fase 2 call sites until
        // they migrate.
        try await link(from: eventId, to: resourceId, kind: .uses)
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
            || msg.contains("not a member")
            || msg.contains("only admins")            { return .permissionDenied(msg) }
        if msg.contains("not found") || msg.contains("archived") { return .notFound(msg) }
        if msg.contains("must be of resource_type")
            || msg.contains("same group")
            || msg.contains("can only use")
            || msg.contains("invalid link tuple")
            || msg.contains("cross-group")
            || msg.contains("self")                    { return .invalidState(msg) }
        return .rpcFailed("\(defaultMsg): \(msg)")
    }
}
