import Foundation
import Supabase

/// Read-only gateway to `public.event_lifecycle_view` (mig 00207).
/// Surfaces the atom-derived event state (`is_live` / `is_past` /
/// `is_cancelled` / `is_closed`) for callers that want the spec-
/// compliant truth per Plans/Active/EventResource.md §17 instead of
/// `resources.status`.
public protocol EventLifecycleRepository: Actor {
    /// Returns the lifecycle projection for a single event resource.
    /// Throws `.notFound` if the resource is missing, archived, or not
    /// `resource_type='event'`.
    func lifecycle(for resourceId: UUID) async throws -> EventLifecycleProjection

    /// Returns all currently-live events in the given group. Ordered by
    /// `starts_at` ascending (earliest first).
    func liveEvents(in groupId: UUID) async throws -> [EventLifecycleProjection]
}

public enum EventLifecycleError: LocalizedError, Sendable, Equatable {
    case notFound
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:           return "Evento no encontrado"
        case .fetchFailed(let m): return "Error: \(m)"
        }
    }
}

// MARK: - Mock

public actor MockEventLifecycleRepository: EventLifecycleRepository {
    public private(set) var rows: [EventLifecycleProjection]
    public var nextError: EventLifecycleError?

    public init(seed: [EventLifecycleProjection] = []) {
        self.rows = seed
    }

    public func lifecycle(for resourceId: UUID) async throws -> EventLifecycleProjection {
        if let err = nextError { nextError = nil; throw err }
        guard let row = rows.first(where: { $0.resourceId == resourceId }) else {
            throw EventLifecycleError.notFound
        }
        return row
    }

    public func liveEvents(in groupId: UUID) async throws -> [EventLifecycleProjection] {
        if let err = nextError { nextError = nil; throw err }
        return rows
            .filter { $0.groupId == groupId && $0.isLive }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
    }

    /// Test helper.
    public func seed(_ row: EventLifecycleProjection) {
        rows.append(row)
    }
}

// MARK: - Live

public actor LiveEventLifecycleRepository: EventLifecycleRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func lifecycle(for resourceId: UUID) async throws -> EventLifecycleProjection {
        do {
            return try await client
                .from("event_lifecycle_view")
                .select("*")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .single()
                .execute()
                .value
        } catch {
            let msg = (error as NSError).localizedDescription
            if msg.contains("0 rows") || msg.contains("PGRST116") {
                throw EventLifecycleError.notFound
            }
            throw EventLifecycleError.fetchFailed(msg)
        }
    }

    public func liveEvents(in groupId: UUID) async throws -> [EventLifecycleProjection] {
        do {
            return try await client
                .from("event_lifecycle_view")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .eq("is_live", value: "true")
                .order("starts_at", ascending: true)
                .execute()
                .value
        } catch {
            throw EventLifecycleError.fetchFailed((error as NSError).localizedDescription)
        }
    }
}
