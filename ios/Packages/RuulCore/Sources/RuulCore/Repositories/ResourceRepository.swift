import Foundation
import Supabase

/// Read-only polymorphic gateway to `public.resources`. Returns rows
/// of any `ResourceType`. Writes still flow through resource-type-
/// specific repos (V1: `EventRepository`); the SQL trigger
/// `events_sync_to_resources` (mig 00039) mirrors them into the
/// resources table automatically.
///
/// Date-bound queries (e.g. "next 10 events starting from today") stay
/// on `EventRepository` for now — the resources table has no flat
/// `starts_at` column, only `metadata` jsonb. Phase 2 may add per-type
/// projection views or generated columns; until then, use this repo
/// for type-bound polymorphic listing and per-id detail fetches.
public protocol ResourceRepository: Actor {
    /// Lists resources in a group, optionally filtering by types and statuses.
    /// - Parameters:
    ///   - groupId: scope.
    ///   - types: required — at least one. Pass `[.event]` for V1 callers.
    ///   - statuses: optional — `nil` means any status.
    ///   - limit: server cap.
    func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow]

    /// Fetches a single resource row by id. Throws `ResourceRowError.notFound`
    /// when the id is unknown or RLS hides it.
    func resource(_ id: UUID) async throws -> ResourceRow

    /// Links an existing resource to a ResourceSeries via
    /// `resources.series_id`. Used by EventResourceBuilder when the
    /// wizard's recurrence capability is enabled — after creating the
    /// event (via the events table dual-write trigger), the resources
    /// row needs its series_id set.
    func setSeriesId(_ seriesId: UUID, on resourceId: UUID) async throws
}

// MARK: - Mock

public actor MockResourceRepository: ResourceRepository {
    public private(set) var rows: [ResourceRow]
    public var nextFetchError: ResourceRowError?

    public init(seed: [ResourceRow] = []) {
        self.rows = seed
    }

    public func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow] {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        let typeSet = Set(types.map { $0.rawString })
        let statusSet = statuses.map(Set.init)
        return rows
            .filter { $0.groupId == groupId }
            .filter { typeSet.contains($0.resourceType.rawString) }
            .filter { row in
                guard let statuses = statusSet else { return true }
                return statuses.contains(row.status)
            }
            .prefix(limit)
            .map { $0 }
    }

    public func resource(_ id: UUID) async throws -> ResourceRow {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        guard let row = rows.first(where: { $0.id == id }) else {
            throw ResourceRowError.notFound
        }
        return row
    }

    public func setSeriesId(_ seriesId: UUID, on resourceId: UUID) async throws {
        // Mock no-op — we don't model series_id on ResourceRow yet in
        // mock since the column was added in mig 00078 and the iOS
        // model doesn't surface it as a stored field. Tests for series
        // linkage would need to extend the mock.
        _ = seriesId
        _ = resourceId
    }

    /// Test helper: append a row to the in-memory store.
    public func seed(_ row: ResourceRow) {
        rows.append(row)
    }
}

// MARK: - Live

public actor LiveResourceRepository: ResourceRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func list(
        in groupId: UUID,
        types: [ResourceType],
        statuses: [String]?,
        limit: Int
    ) async throws -> [ResourceRow] {
        let typeStrings = types.map { $0.rawString }
        do {
            var query = client
                .from("resources")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .in("resource_type", values: typeStrings)
            if let statuses {
                query = query.in("status", values: statuses)
            }
            return try await query
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }

    public func resource(_ id: UUID) async throws -> ResourceRow {
        do {
            return try await client
                .from("resources")
                .select("*")
                .eq("id", value: id.uuidString.lowercased())
                .single()
                .execute()
                .value
        } catch {
            // Supabase returns 406/PGRST116 on missing single — surface as notFound.
            if (error as NSError).localizedDescription.contains("0 rows") {
                throw ResourceRowError.notFound
            }
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }

    public func setSeriesId(_ seriesId: UUID, on resourceId: UUID) async throws {
        struct Patch: Encodable { let series_id: String }
        do {
            _ = try await client
                .from("resources")
                .update(Patch(series_id: seriesId.uuidString.lowercased()))
                .eq("id", value: resourceId.uuidString.lowercased())
                .execute()
        } catch {
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }
}
