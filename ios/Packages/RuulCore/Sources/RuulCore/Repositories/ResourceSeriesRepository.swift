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
    /// Fetches a single series by id. Returns nil when not found (rather
    /// than throwing) so callers can degrade gracefully — e.g. the
    /// rotation Resource Detail section collapses to "no rotation
    /// configured" instead of bubbling up an error.
    func fetchById(_ id: UUID) async throws -> ResourceSeries?
    /// Tier 5 (mig 00132): asks the server who should host occurrence
    /// `cycle` of the given series. Reads
    /// `resource_series.metadata.capability_configs.rotation` to resolve
    /// participants + order + replacementPolicy. Returns nil when:
    /// no rotation cap_config, empty participants, or skip_to_next
    /// exhausted (all inactive).
    func nextHostForSeries(seriesId: UUID, cycle: Int) async throws -> UUID?
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
    /// Mock-only override for `nextHostForSeries`. Keyed by (seriesId, cycle).
    /// Lets tests stub rotation results without round-tripping a fake
    /// `participants[]` through the in-process metadata.
    private var rotationStubs: [String: UUID] = [:]

    public init(seed: [ResourceSeries] = []) { self.rows = seed }

    public func list(groupId: UUID) async throws -> [ResourceSeries] {
        rows.filter { $0.groupId == groupId }
    }

    public func listActive(groupId: UUID) async throws -> [ResourceSeries] {
        rows.filter { $0.groupId == groupId && $0.active }
    }

    public func fetchById(_ id: UUID) async throws -> ResourceSeries? {
        rows.first(where: { $0.id == id })
    }

    public func nextHostForSeries(seriesId: UUID, cycle: Int) async throws -> UUID? {
        rotationStubs["\(seriesId.uuidString.lowercased()):\(cycle)"]
    }

    /// Test helper: register a deterministic host for a (series, cycle).
    public func stubRotation(seriesId: UUID, cycle: Int, host: UUID) {
        rotationStubs["\(seriesId.uuidString.lowercased()):\(cycle)"] = host
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

    public func fetchById(_ id: UUID) async throws -> ResourceSeries? {
        do {
            let rows: [ResourceSeries] = try await client
                .from("resource_series")
                .select("*")
                .eq("id", value: id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            throw ResourceSeriesError.rpcFailed(error.localizedDescription)
        }
    }

    public func nextHostForSeries(seriesId: UUID, cycle: Int) async throws -> UUID? {
        struct Params: Encodable {
            let p_series_id: String
            let p_cycle: Int
        }
        do {
            // The RPC returns a bare uuid or null. Decoder hits .null →
            // optional UUID, otherwise the string is parsed by Codable.
            let raw: UUID? = try await client
                .rpc("next_host_for_series", params: Params(
                    p_series_id: seriesId.uuidString.lowercased(),
                    p_cycle:     cycle
                ))
                .execute()
                .value
            return raw
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
