import Foundation

public extension ResourceRow {
    /// Encodes an in-memory `Event` into a polymorphic `ResourceRow` so the
    /// universal detail surface can render events without a DB round-trip.
    /// Mirrors the metadata jsonb that the dual-write trigger
    /// (`sync_event_to_resource`, mig 00039) writes server-side — keep the
    /// keys aligned with `ResourceRow+Event.decodeAsEvent()`.
    ///
    /// Used by the iOS shell when wiring `UniversalResourceDetailView` for
    /// an event. Optimistic updates on the local `Event` flow through here
    /// so the summary descriptors, cover, etc. reflect the latest state
    /// before the server confirms.
    static func fromEvent(_ event: Event) -> ResourceRow {
        let metadata = JSONConfig.object([
            "title":                     .string(event.title),
            "starts_at":                 .string(iso8601String(event.startsAt)),
            "ends_at":                   event.endsAt.map { .string(iso8601String($0)) } ?? .null,
            "duration_minutes":          .int(event.durationMinutes),
            "host_id":                   event.hostId.map { .string($0.uuidString.lowercased()) } ?? .null,
            "description":               event.description.map(JSONConfig.string) ?? .null,
            "cover_image_url":           event.coverImageURL.map { .string($0.absoluteString) } ?? .null,
            "cover_image_name":          event.coverImageName.map(JSONConfig.string) ?? .null,
            "location_name":             event.locationName.map(JSONConfig.string) ?? .null,
            "location_lat":              event.locationLat.map(JSONConfig.double) ?? .null,
            "location_lng":              event.locationLng.map(JSONConfig.double) ?? .null,
            "capacity_max":              event.capacityMax.map(JSONConfig.int) ?? .null,
            "max_plus_ones_per_member":  .int(event.maxPlusOnesPerMember),
            "allow_plus_ones":           .bool(event.allowPlusOnes),
            "apply_rules":               .bool(event.applyRules),
            "is_recurring_generated":    .bool(event.isRecurringGenerated),
            "parent_event_id":           event.parentEventId.map { .string($0.uuidString.lowercased()) } ?? .null,
            "cycle_number":              event.cycleNumber.map(JSONConfig.int) ?? .null,
            "rsvp_deadline":             event.rsvpDeadline.map { .string(iso8601String($0)) } ?? .null,
            "closed_at":                 event.closedAt.map { .string(iso8601String($0)) } ?? .null,
            "cancellation_reason":       event.cancellationReason.map(JSONConfig.string) ?? .null
        ])

        return ResourceRow(
            id: event.id,
            groupId: event.groupId,
            resourceType: .event,
            status: event.status.rawValue,
            metadata: metadata,
            createdBy: event.createdBy,
            createdAt: event.createdAt,
            updatedAt: event.updatedAt
        )
    }

    /// Format the ISO8601 string in the same shape the Postgres
    /// `to_jsonb(timestamptz)` writes — fractional seconds + UTC offset —
    /// so decoders that round-trip an encoded ResourceRow match the
    /// trigger output exactly.
    private static func iso8601String(_ date: Date) -> String {
        Self.iso8601Frac.string(from: date)
    }

    /// ISO8601 formatter w/ fractional seconds. Kept fileprivate to this
    /// extension; `ResourceRow+Event.swift` declares its own pair for
    /// decoding. Sendable-safe under Swift 6 via `nonisolated(unsafe)`
    /// because `ISO8601DateFormatter` post-configuration is thread-safe
    /// for `string(from:)`.
    fileprivate nonisolated(unsafe) static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
