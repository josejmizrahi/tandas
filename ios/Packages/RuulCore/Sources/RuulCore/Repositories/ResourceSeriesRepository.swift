import Foundation
import Supabase

public enum ResourceSeriesError: Error, Equatable {
    case rpcFailed(String)
    case notFound
}

/// Reads/writes for `public.resource_series`.
public protocol ResourceSeriesRepository: Actor {
    /// Lists all series (any state) for a group.
    func list(groupId: UUID) async throws -> [ResourceSeries]
    /// Lists ACTIVE series only — useful for "what's currently recurring?".
    func listActive(groupId: UUID) async throws -> [ResourceSeries]
    /// Creates a new series row. Caller decides whether to immediately
    /// generate occurrences or wait for the recurrence cron.
    func create(_ series: ResourceSeries) async throws -> ResourceSeries
    /// Toggles a series's `active` flag. Inactive series stop generating
    /// occurrences but keep their history.
    func setActive(seriesId: UUID, active: Bool) async throws
}

// MARK: - Mock

public actor MockResourceSeriesRepository: ResourceSeriesRepository {
    private var rows: [ResourceSeries]

    public init(seed: [ResourceSeries] = []) { self.rows = seed }

    public func list(groupId: UUID) async throws -> [ResourceSeries] {
        rows.filter { $0.groupId == groupId }
    }

    public func listActive(groupId: UUID) async throws -> [ResourceSeries] {
        rows.filter { $0.groupId == groupId && $0.active }
    }

    public func create(_ series: ResourceSeries) async throws -> ResourceSeries {
        rows.append(series)
        return series
    }

    public func setActive(seriesId: UUID, active: Bool) async throws {
        guard let idx = rows.firstIndex(where: { $0.id == seriesId }) else {
            throw ResourceSeriesError.notFound
        }
        let r = rows[idx]
        rows[idx] = ResourceSeries(
            id: r.id,
            groupId: r.groupId,
            resourceType: r.resourceType,
            pattern: r.pattern,
            metadata: r.metadata,
            active: active,
            createdBy: r.createdBy,
            createdAt: r.createdAt,
            updatedAt: .now
        )
    }
}

// MARK: - Live

public actor LiveResourceSeriesRepository: ResourceSeriesRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(groupId: UUID) async throws -> [ResourceSeries] {
        do {
            return try await client
                .from("resource_series")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw ResourceSeriesError.rpcFailed(error.localizedDescription)
        }
    }

    public func listActive(groupId: UUID) async throws -> [ResourceSeries] {
        do {
            return try await client
                .from("resource_series")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .eq("active", value: true)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw ResourceSeriesError.rpcFailed(error.localizedDescription)
        }
    }

    public func create(_ series: ResourceSeries) async throws -> ResourceSeries {
        do {
            return try await client
                .from("resource_series")
                .insert(series)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw ResourceSeriesError.rpcFailed(error.localizedDescription)
        }
    }

    public func setActive(seriesId: UUID, active: Bool) async throws {
        struct Patch: Encodable { let active: Bool }
        do {
            _ = try await client
                .from("resource_series")
                .update(Patch(active: active))
                .eq("id", value: seriesId.uuidString.lowercased())
                .execute()
        } catch {
            throw ResourceSeriesError.rpcFailed(error.localizedDescription)
        }
    }
}
