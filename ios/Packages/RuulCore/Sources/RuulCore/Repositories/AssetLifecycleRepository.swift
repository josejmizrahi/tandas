import Foundation
import Supabase

/// Write-path for the canonical asset spec lifecycle (mig 00200).
///
/// Wraps the 9 SECURITY DEFINER RPCs that materialize asset atoms:
///   - assign_custody       / release_custody
///   - log_maintenance      / complete_maintenance
///   - report_damage
///   - record_valuation
///   - transfer_asset
///   - check_out_asset      / check_in_asset
///   - record_asset_usage
///
/// Reads (current_custodian, valuation, maintenance_status, usage_history)
/// flow through `ResourceRepository` + dedicated views surfaced via
/// generic Postgrest selects in the consumer view layer.
///
/// All RPCs are gated server-side by `is_group_member`; iOS gates
/// CTAs on the matching capability being enabled on the resource.
public protocol AssetLifecycleRepository: Actor {
    /// Designates a custodian for the asset. The previous custodian (if
    /// any) is implicitly replaced. Emits `custodyAssigned`.
    func assignCustody(
        asset assetId: UUID,
        to custodianMemberId: UUID,
        notes: String?
    ) async throws

    /// Releases the current custody. Asset returns to group-level
    /// custody (no individual holder). Emits `custodyReleased`.
    func releaseCustody(asset assetId: UUID, notes: String?) async throws

    /// Logs a maintenance task. Returns the system_event id; the same id
    /// is what `completeMaintenance` consumes. Emits `maintenanceLogged`.
    func logMaintenance(
        asset assetId: UUID,
        kind: String,
        notes: String?,
        costCents: Int64?,
        currency: String?
    ) async throws -> UUID

    /// Marks a previously-logged maintenance task as done. Append-only —
    /// emits a separate `maintenanceCompleted` atom referencing the
    /// original event id; the projection joins them.
    func completeMaintenance(eventId: UUID, notes: String?) async throws

    /// Reports damage. Severity must be one of minor|moderate|major|total.
    /// Emits `damageReported`. Returns the system_event id.
    func reportDamage(
        asset assetId: UUID,
        severity: AssetDamageSeverity,
        notes: String?,
        estimatedCostCents: Int64?,
        currency: String?
    ) async throws -> UUID

    /// Appends a valuation point. Latest projection lives in
    /// `asset_valuation_view`. Emits `valuationRecorded`.
    func recordValuation(
        asset assetId: UUID,
        valueCents: Int64,
        currency: String?,
        source: String?,
        notes: String?
    ) async throws -> UUID

    /// SharedMoney P1 (asset valuation ↔ contribution link): reads the
    /// MOST RECENT row from `asset_valuation_view` for this asset.
    /// Used by `ContributeToSharedMoneySheet` when the user toggles
    /// in-kind on a contribution against an asset — the amount field
    /// auto-pre-fills from this valuation so the warehouse case
    /// ("aporté el terreno valorado en $5M") has a single source of
    /// truth.
    ///
    /// Returns nil when the asset has no valuation history yet (the
    /// `valuation` capability is optional). Sheet falls back to manual
    /// entry in that case.
    func latestValuation(asset assetId: UUID) async throws -> AssetValuation?

    /// Transfers ownership to a member, or back to the group (nil).
    /// Updates metadata.owner_id + emits `assetTransferred`. Custody is
    /// independent and unchanged by this call.
    func transferAsset(
        asset assetId: UUID,
        to memberId: UUID?,
        notes: String?
    ) async throws

    /// Records a checkout (physical handover for temporary use).
    /// Distinct from custody — a custodian can check out without
    /// releasing custody. Defaults to self when `to` is nil.
    /// Emits `assetCheckedOut`.
    func checkOutAsset(
        asset assetId: UUID,
        to memberId: UUID?,
        expectedReturnAt: Date?,
        notes: String?
    ) async throws -> UUID

    /// Closes the prior checkout. Anyone in the group can mark it
    /// returned; condition_notes free-form for damage signalling.
    /// Emits `assetCheckedIn`.
    func checkInAsset(asset assetId: UUID, conditionNotes: String?) async throws

    /// Appends an `assetUsed` atom. Optional `units` for inventory-style
    /// assets (rolls, copies, bytes).
    func recordUsage(
        asset assetId: UUID,
        notes: String?,
        units: Int?
    ) async throws -> UUID
}

public enum AssetDamageSeverity: String, Codable, Sendable, CaseIterable {
    case minor
    case moderate
    case major
    case total

    public var label: String {
        switch self {
        case .minor:    return "Leve"
        case .moderate: return "Moderado"
        case .major:    return "Grave"
        case .total:    return "Pérdida total"
        }
    }
}

public enum AssetLifecycleError: LocalizedError, Sendable {
    case permissionDenied(String)
    case notFound(String)
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

public actor MockAssetLifecycleRepository: AssetLifecycleRepository {
    public private(set) var custodyAssignments: [(UUID, UUID)] = []
    public private(set) var custodyReleases: [UUID] = []
    public private(set) var maintenanceLogs: [(UUID, String, Int64?)] = []
    public private(set) var maintenanceCompletions: [UUID] = []
    public private(set) var damageReports: [(UUID, AssetDamageSeverity)] = []
    public private(set) var valuations: [(UUID, Int64, String?)] = []
    public private(set) var transfers: [(UUID, UUID?)] = []
    public private(set) var checkOuts: [(UUID, UUID?)] = []
    public private(set) var checkIns: [UUID] = []
    public private(set) var usages: [(UUID, Int?)] = []

    public var nextError: AssetLifecycleError?

    public init() {}

    public func assignCustody(asset assetId: UUID, to custodianMemberId: UUID, notes: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        custodyAssignments.append((assetId, custodianMemberId))
    }
    public func releaseCustody(asset assetId: UUID, notes: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        custodyReleases.append(assetId)
    }
    public func logMaintenance(
        asset assetId: UUID, kind: String, notes: String?, costCents: Int64?, currency: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        let id = UUID()
        maintenanceLogs.append((assetId, kind, costCents))
        return id
    }
    public func completeMaintenance(eventId: UUID, notes: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        maintenanceCompletions.append(eventId)
    }
    public func reportDamage(
        asset assetId: UUID, severity: AssetDamageSeverity, notes: String?,
        estimatedCostCents: Int64?, currency: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        damageReports.append((assetId, severity))
        return UUID()
    }
    public func recordValuation(
        asset assetId: UUID, valueCents: Int64, currency: String?, source: String?, notes: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        valuations.append((assetId, valueCents, currency))
        return UUID()
    }
    public func latestValuation(asset assetId: UUID) async throws -> AssetValuation? {
        if let err = nextError { nextError = nil; throw err }
        // Mock walks the append-only log backwards for the asset's
        // most-recent entry. Real impl reads the view ordered desc.
        guard let row = valuations.last(where: { $0.0 == assetId }) else { return nil }
        return AssetValuation(
            assetId: row.0,
            groupId: UUID(),
            valueCents: row.1,
            currency: row.2 ?? "MXN",
            source: nil,
            notes: nil,
            recordedByUserId: nil,
            recordedAt: .now
        )
    }
    public func transferAsset(asset assetId: UUID, to memberId: UUID?, notes: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        transfers.append((assetId, memberId))
    }
    public func checkOutAsset(
        asset assetId: UUID, to memberId: UUID?, expectedReturnAt: Date?, notes: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        checkOuts.append((assetId, memberId))
        return UUID()
    }
    public func checkInAsset(asset assetId: UUID, conditionNotes: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        checkIns.append(assetId)
    }
    public func recordUsage(asset assetId: UUID, notes: String?, units: Int?) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        usages.append((assetId, units))
        return UUID()
    }
}

// MARK: - Live

public actor LiveAssetLifecycleRepository: AssetLifecycleRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public func assignCustody(
        asset assetId: UUID, to custodianMemberId: UUID, notes: String?
    ) async throws {
        struct Params: Encodable {
            let p_asset_id: String
            let p_custodian_member_id: String
            let p_notes: String?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_custodian_member_id: custodianMemberId.uuidString.lowercased(),
            p_notes: notes
        )
        do {
            _ = try await client.rpc("assign_custody", params: params).execute()
        } catch {
            throw mapError(error, default: "assign_custody failed")
        }
    }

    public func releaseCustody(asset assetId: UUID, notes: String?) async throws {
        struct Params: Encodable {
            let p_asset_id: String
            let p_notes: String?
        }
        let params = Params(p_asset_id: assetId.uuidString.lowercased(), p_notes: notes)
        do {
            _ = try await client.rpc("release_custody", params: params).execute()
        } catch {
            throw mapError(error, default: "release_custody failed")
        }
    }

    public func logMaintenance(
        asset assetId: UUID, kind: String, notes: String?, costCents: Int64?, currency: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_kind: String
            let p_notes: String?
            let p_cost_cents: Int64?
            let p_currency: String
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_kind: kind,
            p_notes: notes,
            p_cost_cents: costCents,
            p_currency: currency ?? "MXN"
        )
        do {
            let id: UUID = try await client.rpc("log_maintenance", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "log_maintenance failed")
        }
    }

    public func completeMaintenance(eventId: UUID, notes: String?) async throws {
        struct Params: Encodable {
            let p_maintenance_event_id: String
            let p_notes: String?
        }
        let params = Params(
            p_maintenance_event_id: eventId.uuidString.lowercased(),
            p_notes: notes
        )
        do {
            _ = try await client.rpc("complete_maintenance", params: params).execute()
        } catch {
            throw mapError(error, default: "complete_maintenance failed")
        }
    }

    public func reportDamage(
        asset assetId: UUID, severity: AssetDamageSeverity, notes: String?,
        estimatedCostCents: Int64?, currency: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_severity: String
            let p_notes: String?
            let p_estimated_cost_cents: Int64?
            let p_currency: String
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_severity: severity.rawValue,
            p_notes: notes,
            p_estimated_cost_cents: estimatedCostCents,
            p_currency: currency ?? "MXN"
        )
        do {
            let id: UUID = try await client.rpc("report_damage", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "report_damage failed")
        }
    }

    public func recordValuation(
        asset assetId: UUID, valueCents: Int64, currency: String?, source: String?, notes: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_value_cents: Int64
            let p_currency: String
            let p_source: String?
            let p_notes: String?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_value_cents: valueCents,
            p_currency: currency ?? "MXN",
            p_source: source,
            p_notes: notes
        )
        do {
            let id: UUID = try await client.rpc("record_valuation", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "record_valuation failed")
        }
    }

    public func latestValuation(asset assetId: UUID) async throws -> AssetValuation? {
        // Reads `asset_valuation_view` ordered by recorded_at desc.
        // The view is an atom log (one row per record_valuation call),
        // so the first row = the latest valuation.
        do {
            let rows: [AssetValuation] = try await client
                .from("asset_valuation_view")
                .select()
                .eq("asset_id", value: assetId.uuidString.lowercased())
                .order("recorded_at", ascending: false)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            throw mapError(error, default: "asset_valuation_view read failed")
        }
    }

    public func transferAsset(
        asset assetId: UUID, to memberId: UUID?, notes: String?
    ) async throws {
        struct Params: Encodable {
            let p_asset_id: String
            let p_to_member_id: String?
            let p_notes: String?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_to_member_id: memberId?.uuidString.lowercased(),
            p_notes: notes
        )
        do {
            _ = try await client.rpc("transfer_asset", params: params).execute()
        } catch {
            throw mapError(error, default: "transfer_asset failed")
        }
    }

    public func checkOutAsset(
        asset assetId: UUID, to memberId: UUID?, expectedReturnAt: Date?, notes: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_to_member_id: String?
            let p_expected_return_at: String?
            let p_notes: String?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_to_member_id: memberId?.uuidString.lowercased(),
            p_expected_return_at: expectedReturnAt.map(isoString),
            p_notes: notes
        )
        do {
            let id: UUID = try await client.rpc("check_out_asset", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "check_out_asset failed")
        }
    }

    public func checkInAsset(asset assetId: UUID, conditionNotes: String?) async throws {
        struct Params: Encodable {
            let p_asset_id: String
            let p_condition_notes: String?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_condition_notes: conditionNotes
        )
        do {
            _ = try await client.rpc("check_in_asset", params: params).execute()
        } catch {
            throw mapError(error, default: "check_in_asset failed")
        }
    }

    public func recordUsage(asset assetId: UUID, notes: String?, units: Int?) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_notes: String?
            let p_units: Int?
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_notes: notes,
            p_units: units
        )
        do {
            let id: UUID = try await client.rpc("record_asset_usage", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "record_asset_usage failed")
        }
    }

    private func mapError(_ error: Error, default defaultMsg: String) -> AssetLifecycleError {
        let msg = (error as NSError).localizedDescription
        if msg.contains("permission denied") || msg.contains("not a member") {
            return .permissionDenied(msg)
        }
        if msg.contains("not found") { return .notFound(msg) }
        if msg.contains("required")
            || msg.contains("must be")
            || msg.contains("cannot")
            || msg.contains("severity must be")
            || msg.contains("not active") { return .invalidState(msg) }
        return .rpcFailed("\(defaultMsg): \(msg)")
    }
}
