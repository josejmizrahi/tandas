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

    /// Polymorphic "in use right now" projection for a group. Joins
    /// `asset_current_custodian_view` + `space_occupancy_view` against
    /// `resources` for titles. Sorted by `since` desc (most recent
    /// claim first). Empty array when nothing is in use. Slot in-use
    /// is intentionally not surfaced (semantics ambiguous).
    func inUseInGroup(_ groupId: UUID) async throws -> [InUseProjection]
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

    public var seededInUse: [InUseProjection] = []

    public func inUseInGroup(_ groupId: UUID) async throws -> [InUseProjection] {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        return seededInUse.filter { $0.groupId == groupId }
    }

    /// Test helper: append a row to the in-memory store.
    public func seed(_ row: ResourceRow) {
        rows.append(row)
    }

    /// Test helper: seed in-use projections.
    public func seedInUse(_ items: [InUseProjection]) {
        seededInUse.append(contentsOf: items)
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

    /// Wire-row for `asset_current_custodian_view`.
    private struct CustodianRow: Decodable {
        let assetId: UUID
        let groupId: UUID
        let custodianMemberId: UUID
        let assignedAt: Date

        enum CodingKeys: String, CodingKey {
            case assetId           = "asset_id"
            case groupId           = "group_id"
            case custodianMemberId = "custodian_member_id"
            case assignedAt        = "assigned_at"
        }
    }

    /// Wire-row for `space_occupancy_view`.
    private struct OccupancyRow: Decodable {
        let spaceId: UUID
        let groupId: UUID
        let memberId: UUID
        let checkedInAt: Date

        enum CodingKeys: String, CodingKey {
            case spaceId      = "space_id"
            case groupId      = "group_id"
            case memberId     = "member_id"
            case checkedInAt  = "checked_in_at"
        }
    }

    public func inUseInGroup(_ groupId: UUID) async throws -> [InUseProjection] {
        let gid = groupId.uuidString.lowercased()
        do {
            // Both projection views are server-pre-filtered to active
            // claims only — no `is_null` predicates needed on the iOS
            // side. Parallel fetch keeps the cluster snappy.
            async let custodiansTask: [CustodianRow] = client
                .from("asset_current_custodian_view")
                .select("asset_id, group_id, custodian_member_id, assigned_at")
                .eq("group_id", value: gid)
                .execute()
                .value

            async let occupanciesTask: [OccupancyRow] = client
                .from("space_occupancy_view")
                .select("space_id, group_id, member_id, last_check_in_action_id, checked_in_at, booking_id, notes")
                .eq("group_id", value: gid)
                .execute()
                .value

            let custodians = try await custodiansTask
            let occupancies = try await occupanciesTask

            let resourceIds = Set(
                custodians.map(\.assetId) + occupancies.map(\.spaceId)
            )
            guard !resourceIds.isEmpty else { return [] }

            let idStrings = resourceIds.map { $0.uuidString.lowercased() }
            let rows: [ResourceRow] = try await client
                .from("resources")
                .select("*")
                .in("id", values: idStrings)
                .execute()
                .value

            var byId: [UUID: ResourceRow] = [:]
            for row in rows { byId[row.id] = row }

            var items: [InUseProjection] = []
            for c in custodians {
                guard let row = byId[c.assetId] else { continue }
                items.append(InUseProjection(
                    id: row.id,
                    groupId: row.groupId,
                    resourceType: .asset,
                    title: Self.title(of: row, fallback: "Activo"),
                    holderMemberId: c.custodianMemberId,
                    since: c.assignedAt
                ))
            }
            for o in occupancies {
                guard let row = byId[o.spaceId] else { continue }
                items.append(InUseProjection(
                    id: row.id,
                    groupId: row.groupId,
                    resourceType: .space,
                    title: Self.title(of: row, fallback: "Espacio"),
                    holderMemberId: o.memberId,
                    since: o.checkedInAt
                ))
            }
            return items.sorted { $0.since > $1.since }
        } catch {
            throw ResourceRowError.fetchFailed(error.localizedDescription)
        }
    }

    /// Mirrors the polymorphic title lookup other surfaces use (see
    /// `GroupBalancesView`, `GroupTransactionsView`): assets/spaces
    /// store `metadata.name`; V1 events mirrored from the events
    /// table use `metadata.title`. Falls back per type when neither
    /// is present.
    private static func title(of row: ResourceRow, fallback: String) -> String {
        if let name = row.metadata["name"]?.stringValue, !name.isEmpty {
            return name
        }
        if let title = row.metadata["title"]?.stringValue, !title.isEmpty {
            return title
        }
        return fallback
    }
}
