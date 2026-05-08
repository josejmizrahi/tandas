import Foundation

/// Projection: a `ResourceRow` with `resource_type == .event` decodes
/// back into a concrete `Event`. This is the inverse of the dual-write
/// trigger `sync_event_to_resource()` (migration 00039) which projects
/// `events.*` into `resources.metadata` jsonb.
///
/// Kept in RuulCore so any consumer holding a `[ResourceRow]` (e.g.
/// HomeCoordinator post Plan 6) can fan out to typed handles cheaply.
public extension ResourceRow {
    /// Decodes the row into an `Event`. Throws if the row's
    /// resource_type isn't `.event` or required keys are missing.
    func decodeAsEvent() throws -> Event {
        guard resourceType == .event else {
            throw ResourceRowError.typeMismatch(expected: .event, got: resourceType)
        }

        guard let startsAtString = metadata["starts_at"]?.stringValue else {
            throw ResourceRowError.missingMetadataKey("starts_at")
        }
        guard let startsAt = ResourceRow.parseISO8601(startsAtString) else {
            throw ResourceRowError.metadataDecodeFailed("starts_at not ISO8601")
        }

        let title = metadata["title"]?.stringValue ?? ""
        let durationMinutes = metadata["duration_minutes"]?.intValue ?? 180
        let applyRules = metadata["apply_rules"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        } ?? true

        let endsAt = (metadata["ends_at"]?.stringValue).flatMap(ResourceRow.parseISO8601)
        let rsvpDeadline = (metadata["rsvp_deadline"]?.stringValue).flatMap(ResourceRow.parseISO8601)
        let closedAt = (metadata["closed_at"]?.stringValue).flatMap(ResourceRow.parseISO8601)

        let coverImageName = metadata["cover_image_name"]?.stringValue
        let coverImageURL = (metadata["cover_image_url"]?.stringValue).flatMap(URL.init(string:))
        let description = metadata["description"]?.stringValue
        let locationName = metadata["location_name"]?.stringValue
        let locationLat = metadata["location_lat"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let locationLng = metadata["location_lng"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let hostId = (metadata["host_id"]?.stringValue).flatMap(UUID.init(uuidString:))
        let parentEventId = (metadata["parent_event_id"]?.stringValue).flatMap(UUID.init(uuidString:))
        let cycleNumber = metadata["cycle_number"]?.intValue
        let isRecurringGenerated = (metadata["is_recurring_generated"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        }) ?? false
        let cancellationReason = metadata["cancellation_reason"]?.stringValue
        let capacityMax = metadata["capacity_max"]?.intValue
        let allowPlusOnes = (metadata["allow_plus_ones"].flatMap { v -> Bool? in
            if case .bool(let b) = v { return b }
            return nil
        }) ?? false
        let maxPlusOnes = metadata["max_plus_ones_per_member"]?.intValue ?? 0

        let eventStatus = EventStatus(rawValue: status) ?? .upcoming

        return Event(
            id: id,
            groupId: groupId,
            title: title,
            coverImageName: coverImageName,
            coverImageURL: coverImageURL,
            description: description,
            startsAt: startsAt,
            endsAt: endsAt,
            durationMinutes: durationMinutes,
            locationName: locationName,
            locationLat: locationLat,
            locationLng: locationLng,
            hostId: hostId,
            applyRules: applyRules,
            status: eventStatus,
            cancellationReason: cancellationReason,
            isRecurringGenerated: isRecurringGenerated,
            parentEventId: parentEventId,
            cycleNumber: cycleNumber,
            rsvpDeadline: rsvpDeadline,
            closedAt: closedAt,
            createdBy: createdBy,
            createdAt: createdAt,
            capacityMax: capacityMax,
            allowPlusOnes: allowPlusOnes,
            maxPlusOnesPerMember: maxPlusOnes
        )
    }

    /// Parses an ISO8601 string tolerantly: tries with fractional seconds
    /// first (Postgres `to_jsonb(timestamptz)` includes them), then without
    /// (e.g. `ISO8601DateFormatter().string(from:)` defaults).
    /// Returns `nil` if neither parser matches.
    ///
    /// `ISO8601DateFormatter` parsing is thread-safe after configuration;
    /// we use `nonisolated(unsafe)` because the type itself isn't `Sendable`
    /// under Swift 6 strict concurrency.
    fileprivate static func parseISO8601(_ s: String) -> Date? {
        if let d = Self.iso8601Frac.date(from: s) { return d }
        return Self.iso8601Plain.date(from: s)
    }

    fileprivate nonisolated(unsafe) static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    fileprivate nonisolated(unsafe) static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
