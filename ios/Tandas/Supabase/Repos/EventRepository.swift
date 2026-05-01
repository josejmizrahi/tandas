import Foundation
import Supabase

struct EventPatch: Sendable, Equatable {
    var title: String?
    var description: String?
    var coverImageName: String?
    var coverImageURL: URL?
    var startsAt: Date?
    var durationMinutes: Int?
    var locationName: String?
    var locationLat: Double?
    var locationLng: Double?
    var hostId: UUID?
    var applyRules: Bool?
}

protocol EventRepository: Actor {
    func upcomingEvents(in groupId: UUID, limit: Int) async throws -> [Event]
    func pastEvents(in groupId: UUID, limit: Int) async throws -> [Event]
    func event(_ id: UUID) async throws -> Event
    func nextEvent(in groupId: UUID) async throws -> Event?
    func createEvent(_ draft: EventDraft, in groupId: UUID, isRecurringGenerated: Bool) async throws -> Event
    func updateEvent(_ id: UUID, patch: EventPatch) async throws -> Event
    func cancelEvent(_ id: UUID, reason: String?) async throws -> Event
    func closeEvent(_ id: UUID) async throws -> Event
    func setAutoGenerate(groupId: UUID, enabled: Bool) async throws
}

// MARK: - Mock

actor MockEventRepository: EventRepository {
    private(set) var events: [Event] = []
    var nextCreateError: EventError?
    var nextFetchError: EventError?

    init(seed: [Event] = []) { self.events = seed }

    func upcomingEvents(in groupId: UUID, limit: Int) async throws -> [Event] {
        if let err = nextFetchError { nextFetchError = nil; throw err }
        return events
            .filter { $0.groupId == groupId && $0.status.isActive && $0.startsAt >= .now }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(limit)
            .map { $0 }
    }

    func pastEvents(in groupId: UUID, limit: Int) async throws -> [Event] {
        events
            .filter { $0.groupId == groupId && ($0.status == .closed || $0.status == .cancelled || $0.startsAt < .now) }
            .sorted { $0.startsAt > $1.startsAt }
            .prefix(limit)
            .map { $0 }
    }

    func event(_ id: UUID) async throws -> Event {
        guard let e = events.first(where: { $0.id == id }) else { throw EventError.notFound }
        return e
    }

    func nextEvent(in groupId: UUID) async throws -> Event? {
        try? await upcomingEvents(in: groupId, limit: 1).first
    }

    func createEvent(_ draft: EventDraft, in groupId: UUID, isRecurringGenerated: Bool) async throws -> Event {
        if let err = nextCreateError { nextCreateError = nil; throw err }
        let event = Event(
            id: UUID(),
            groupId: groupId,
            title: draft.title,
            coverImageName: draft.coverImageName,
            coverImageURL: draft.coverImageURL,
            description: draft.description.isEmpty ? nil : draft.description,
            startsAt: draft.startsAt,
            durationMinutes: draft.durationMinutes,
            locationName: draft.locationName,
            locationLat: draft.locationLat,
            locationLng: draft.locationLng,
            hostId: draft.hostId,
            applyRules: draft.applyRules,
            isRecurringGenerated: isRecurringGenerated,
            createdAt: .now
        )
        events.append(event)
        return event
    }

    func updateEvent(_ id: UUID, patch: EventPatch) async throws -> Event {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { throw EventError.notFound }
        let e = events[idx]
        let updated = Event(
            id: e.id,
            groupId: e.groupId,
            title: patch.title ?? e.title,
            coverImageName: patch.coverImageName ?? e.coverImageName,
            coverImageURL: patch.coverImageURL ?? e.coverImageURL,
            description: patch.description ?? e.description,
            startsAt: patch.startsAt ?? e.startsAt,
            endsAt: e.endsAt,
            durationMinutes: patch.durationMinutes ?? e.durationMinutes,
            locationName: patch.locationName ?? e.locationName,
            locationLat: patch.locationLat ?? e.locationLat,
            locationLng: patch.locationLng ?? e.locationLng,
            hostId: patch.hostId ?? e.hostId,
            applyRules: patch.applyRules ?? e.applyRules,
            status: e.status,
            cancellationReason: e.cancellationReason,
            isRecurringGenerated: e.isRecurringGenerated,
            parentEventId: e.parentEventId,
            cycleNumber: e.cycleNumber,
            rsvpDeadline: e.rsvpDeadline,
            closedAt: e.closedAt,
            createdBy: e.createdBy,
            createdAt: e.createdAt
        )
        events[idx] = updated
        return updated
    }

    func cancelEvent(_ id: UUID, reason: String?) async throws -> Event {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { throw EventError.notFound }
        let e = events[idx]
        let updated = Event(
            id: e.id, groupId: e.groupId, title: e.title,
            coverImageName: e.coverImageName, coverImageURL: e.coverImageURL,
            description: e.description, startsAt: e.startsAt, endsAt: e.endsAt,
            durationMinutes: e.durationMinutes, locationName: e.locationName,
            locationLat: e.locationLat, locationLng: e.locationLng,
            hostId: e.hostId, applyRules: e.applyRules, status: .cancelled,
            cancellationReason: reason, isRecurringGenerated: e.isRecurringGenerated,
            parentEventId: e.parentEventId, cycleNumber: e.cycleNumber,
            rsvpDeadline: e.rsvpDeadline, closedAt: e.closedAt,
            createdBy: e.createdBy, createdAt: e.createdAt
        )
        events[idx] = updated
        return updated
    }

    func closeEvent(_ id: UUID) async throws -> Event {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { throw EventError.notFound }
        let e = events[idx]
        let updated = Event(
            id: e.id, groupId: e.groupId, title: e.title,
            coverImageName: e.coverImageName, coverImageURL: e.coverImageURL,
            description: e.description, startsAt: e.startsAt, endsAt: e.endsAt,
            durationMinutes: e.durationMinutes, locationName: e.locationName,
            locationLat: e.locationLat, locationLng: e.locationLng,
            hostId: e.hostId, applyRules: e.applyRules, status: .closed,
            cancellationReason: e.cancellationReason, isRecurringGenerated: e.isRecurringGenerated,
            parentEventId: e.parentEventId, cycleNumber: e.cycleNumber,
            rsvpDeadline: e.rsvpDeadline, closedAt: .now,
            createdBy: e.createdBy, createdAt: e.createdAt
        )
        events[idx] = updated
        return updated
    }

    func setAutoGenerate(groupId: UUID, enabled: Bool) async throws {
        // No-op in mock; coordinator tests verify the call shape via spy.
    }
}

// MARK: - Live

actor LiveEventRepository: EventRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func upcomingEvents(in groupId: UUID, limit: Int) async throws -> [Event] {
        do {
            return try await client
                .from("events")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .in("status", values: ["scheduled", "in_progress"])
                .gte("starts_at", value: ISO8601DateFormatter().string(from: .now))
                .order("starts_at", ascending: true)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw EventError.fetchFailed(error.localizedDescription)
        }
    }

    func pastEvents(in groupId: UUID, limit: Int) async throws -> [Event] {
        do {
            return try await client
                .from("events")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .in("status", values: ["completed", "cancelled"])
                .order("starts_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw EventError.fetchFailed(error.localizedDescription)
        }
    }

    func event(_ id: UUID) async throws -> Event {
        do {
            return try await client
                .from("events")
                .select("*")
                .eq("id", value: id.uuidString.lowercased())
                .single()
                .execute()
                .value
        } catch {
            throw EventError.notFound
        }
    }

    func nextEvent(in groupId: UUID) async throws -> Event? {
        struct Params: Encodable { let p_group_id: String }
        do {
            let event: Event? = try? await client
                .rpc("next_event_for_group", params: Params(p_group_id: groupId.uuidString.lowercased()))
                .execute()
                .value
            return event
        }
    }

    func createEvent(_ draft: EventDraft, in groupId: UUID, isRecurringGenerated: Bool) async throws -> Event {
        struct Params: Encodable {
            let p_group_id: String
            let p_title: String
            let p_starts_at: String
            let p_duration_minutes: Int
            let p_location_name: String?
            let p_location_lat: Double?
            let p_location_lng: Double?
            let p_host_id: String?
            let p_cover_image_name: String?
            let p_cover_image_url: String?
            let p_description: String?
            let p_apply_rules: Bool
            let p_is_recurring_generated: Bool
        }
        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_title: draft.title,
            p_starts_at: ISO8601DateFormatter().string(from: draft.startsAt),
            p_duration_minutes: draft.durationMinutes,
            p_location_name: draft.locationName,
            p_location_lat: draft.locationLat,
            p_location_lng: draft.locationLng,
            p_host_id: draft.hostId?.uuidString.lowercased(),
            p_cover_image_name: draft.coverImageName,
            p_cover_image_url: draft.coverImageURL?.absoluteString,
            p_description: draft.description.isEmpty ? nil : draft.description,
            p_apply_rules: draft.applyRules,
            p_is_recurring_generated: isRecurringGenerated
        )
        do {
            return try await client.rpc("create_event_v2", params: params).execute().value
        } catch {
            throw EventError.createFailed(error.localizedDescription)
        }
    }

    func updateEvent(_ id: UUID, patch: EventPatch) async throws -> Event {
        var payload: [String: AnyJSON] = [:]
        if let v = patch.title              { payload["title"] = .string(v) }
        if let v = patch.description        { payload["description"] = .string(v) }
        if let v = patch.coverImageName     { payload["cover_image_name"] = .string(v) }
        if let v = patch.coverImageURL      { payload["cover_image_url"] = .string(v.absoluteString) }
        if let v = patch.startsAt           { payload["starts_at"] = .string(ISO8601DateFormatter().string(from: v)) }
        if let v = patch.durationMinutes    { payload["duration_minutes"] = .integer(v) }
        if let v = patch.locationName       { payload["location"] = .string(v) }
        if let v = patch.locationLat        { payload["location_lat"] = .double(v) }
        if let v = patch.locationLng        { payload["location_lng"] = .double(v) }
        if let v = patch.hostId             { payload["host_id"] = .string(v.uuidString.lowercased()) }
        if let v = patch.applyRules         { payload["apply_rules"] = .bool(v) }

        do {
            return try await client
                .from("events")
                .update(payload)
                .eq("id", value: id.uuidString.lowercased())
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw EventError.updateFailed(error.localizedDescription)
        }
    }

    func cancelEvent(_ id: UUID, reason: String?) async throws -> Event {
        struct Params: Encodable {
            let p_event_id: String
            let p_reason: String?
        }
        do {
            return try await client
                .rpc("cancel_event", params: Params(
                    p_event_id: id.uuidString.lowercased(),
                    p_reason: reason
                ))
                .execute()
                .value
        } catch {
            throw EventError.cancelFailed(error.localizedDescription)
        }
    }

    func closeEvent(_ id: UUID) async throws -> Event {
        struct Params: Encodable { let p_event_id: String }
        do {
            return try await client
                .rpc("close_event_no_fines", params: Params(p_event_id: id.uuidString.lowercased()))
                .execute()
                .value
        } catch {
            throw EventError.closeFailed(error.localizedDescription)
        }
    }

    func setAutoGenerate(groupId: UUID, enabled: Bool) async throws {
        do {
            try await client
                .from("groups")
                .update(["auto_generate_events": enabled])
                .eq("id", value: groupId.uuidString.lowercased())
                .execute()
        } catch {
            throw EventError.updateFailed(error.localizedDescription)
        }
    }
}
