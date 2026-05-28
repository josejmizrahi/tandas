import Foundation

/// Foundation-scope repository for Primitiva 21 (Ritual). Reads via
/// `list_group_resource_series(...)`; writes via
/// `create_resource_series(...)` and `update_resource_series(...)`.
/// Pattern + template_payload jsonb shapes are deferred — the
/// Foundation surface only collects cadence + dates + ritual
/// annotation.
public struct CanonicalRitualsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func listRituals(
        groupId: UUID,
        ritualsOnly: Bool = true,
        includePast: Bool = false
    ) async throws -> [GroupResourceSeries] {
        try await rpc.listGroupResourceSeries(
            groupId: groupId,
            ritualsOnly: ritualsOnly,
            includePast: includePast
        )
    }

    public func createRitual(
        groupId: UUID,
        cadence: RitualCadence,
        startsOn: Date?,
        endsOn: Date?,
        markerKind: RitualMarkerKind,
        meaning: String?
    ) async throws -> UUID {
        let input = CreateResourceSeriesInput(
            groupId: groupId,
            resourceType: "event",
            cadence: cadence.rawValue,
            startsOn: startsOn,
            endsOn: endsOn,
            ritualMeaning: meaning?.trimmedOrNil,
            ritualMarkerKind: markerKind.rawValue
        )
        return try await rpc.createResourceSeries(input)
    }

    public func updateRitual(
        seriesId: UUID,
        meaning: String?,
        markerKind: RitualMarkerKind?,
        endsOn: Date?
    ) async throws {
        let input = UpdateResourceSeriesInput(
            seriesId: seriesId,
            ritualMeaning: meaning?.trimmedOrNil,
            ritualMarkerKind: markerKind?.rawValue,
            endsOn: endsOn
        )
        try await rpc.updateResourceSeries(input)
    }

    /// Convenience: mark a ritual ended (sets `ends_on` to today).
    public func endRitual(seriesId: UUID) async throws {
        try await rpc.updateResourceSeries(
            UpdateResourceSeriesInput(seriesId: seriesId, endsOn: Date())
        )
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
