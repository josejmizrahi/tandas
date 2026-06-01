import Foundation

/// V3-D.23 — Foundation-scope repository for the Calendar Event primitive.
/// Wraps the 11 `*_event(...)` RPCs declared in `RuulRPCClient` so stores
/// and features depend on a small, typed surface instead of poking the
/// SupabaseClient.
///
/// Decoupled from `CanonicalEventsRepository`, which talks to the
/// audit-log surface (`group_events`). They cohabit by design.
public struct CanonicalCalendarEventsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func listEvents(
        groupId: UUID,
        from: Date? = nil,
        to: Date? = nil,
        includeCancelled: Bool = false,
        includeArchived: Bool = false
    ) async throws -> [CalendarEventListItem] {
        try await rpc.listGroupCalendarEvents(
            ListGroupCalendarEventsParams(
                pGroupId: groupId,
                pFrom: from,
                pTo: to,
                pIncludeCancelled: includeCancelled,
                pIncludeArchived: includeArchived
            )
        )
    }

    public func detail(eventId: UUID) async throws -> CalendarEventDetail {
        try await rpc.getCalendarEventDetail(
            GetCalendarEventDetailParams(pEventId: eventId)
        )
    }

    /// V3 D.24 P12B-3 — single round-trip detail summary que envuelve
    /// `get_event_detail` + agrega comments/attachments counts. Caller
    /// puede caer a `detail(...)` legacy si esta RPC falla.
    public func detailSummary(eventId: UUID) async throws -> CalendarEventDetailSummary {
        try await rpc.eventDetailSummary(eventId: eventId)
    }

    public func create(
        groupId: UUID,
        title: String,
        description: String?,
        eventType: CalendarEventType,
        startsAt: Date,
        endsAt: Date?,
        timezone: String?,
        locationName: String?,
        locationAddress: String?,
        locationUrl: String?,
        recurrenceRule: String?,
        visibility: CalendarEventVisibility,
        metadata: [String: RPCJSONValue]? = nil
    ) async throws -> UUID {
        try await rpc.createCalendarEvent(
            CreateCalendarEventParams(
                pGroupId: groupId,
                pTitle: title,
                pDescription: description?.trimmedOrNilCal,
                pEventType: eventType.rawValue,
                pStartsAt: startsAt,
                pEndsAt: endsAt,
                pTimezone: timezone?.trimmedOrNilCal,
                pLocationName: locationName?.trimmedOrNilCal,
                pLocationAddress: locationAddress?.trimmedOrNilCal,
                pLocationUrl: locationUrl?.trimmedOrNilCal,
                pRecurrenceRule: recurrenceRule?.trimmedOrNilCal,
                pVisibility: visibility.rawValue,
                pMetadata: metadata
            )
        )
    }

    public func update(
        eventId: UUID,
        title: String? = nil,
        description: String? = nil,
        eventType: CalendarEventType? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        timezone: String? = nil,
        locationName: String? = nil,
        locationAddress: String? = nil,
        locationUrl: String? = nil,
        recurrenceRule: String? = nil,
        visibility: CalendarEventVisibility? = nil,
        metadata: [String: RPCJSONValue]? = nil
    ) async throws {
        try await rpc.updateCalendarEvent(
            UpdateCalendarEventParams(
                pEventId: eventId,
                pTitle: title?.trimmedOrNilCal,
                pDescription: description,
                pEventType: eventType?.rawValue,
                pStartsAt: startsAt,
                pEndsAt: endsAt,
                pTimezone: timezone?.trimmedOrNilCal,
                pLocationName: locationName,
                pLocationAddress: locationAddress,
                pLocationUrl: locationUrl,
                pRecurrenceRule: recurrenceRule,
                pVisibility: visibility?.rawValue,
                pMetadata: metadata
            )
        )
    }

    public func cancel(eventId: UUID, reason: String? = nil) async throws {
        try await rpc.cancelCalendarEvent(
            CancelCalendarEventParams(pEventId: eventId, pReason: reason?.trimmedOrNilCal)
        )
    }

    public func archive(eventId: UUID) async throws {
        try await rpc.archiveCalendarEvent(ArchiveCalendarEventParams(pEventId: eventId))
    }

    public func addAttendee(
        eventId: UUID,
        membershipId: UUID? = nil,
        invitedEmail: String? = nil,
        invitedPhone: String? = nil,
        displayName: String? = nil,
        role: CalendarEventAttendeeRole = .attendee
    ) async throws -> UUID {
        try await rpc.addCalendarEventAttendee(
            AddCalendarEventAttendeeParams(
                pEventId: eventId,
                pMembershipId: membershipId,
                pInvitedEmail: invitedEmail?.trimmedOrNilCal,
                pInvitedPhone: invitedPhone?.trimmedOrNilCal,
                pDisplayName: displayName?.trimmedOrNilCal,
                pRole: role.rawValue
            )
        )
    }

    public func removeAttendee(attendeeId: UUID) async throws {
        try await rpc.removeCalendarEventAttendee(
            RemoveCalendarEventAttendeeParams(pEventAttendeeId: attendeeId)
        )
    }

    public func respond(
        eventId: UUID,
        status: CalendarEventRSVPStatus,
        note: String? = nil
    ) async throws -> UUID {
        try await rpc.respondCalendarEvent(
            RespondCalendarEventParams(
                pEventId: eventId,
                pRsvpStatus: status.rawValue,
                pRsvpNote: note?.trimmedOrNilCal
            )
        )
    }

    public func addReminder(
        eventId: UUID,
        reminderType: CalendarEventReminderType = .push,
        offsetMinutes: Int = 60,
        target: CalendarEventReminderTarget = .attendees,
        targetMembershipId: UUID? = nil
    ) async throws -> UUID {
        try await rpc.addCalendarEventReminder(
            AddCalendarEventReminderParams(
                pEventId: eventId,
                pReminderType: reminderType.rawValue,
                pOffsetMinutes: offsetMinutes,
                pTarget: target.rawValue,
                pTargetMembershipId: target == .specificMembership ? targetMembershipId : nil
            )
        )
    }

    public func removeReminder(reminderId: UUID) async throws {
        try await rpc.removeCalendarEventReminder(
            RemoveCalendarEventReminderParams(pReminderId: reminderId)
        )
    }
}

private extension String {
    var trimmedOrNilCal: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
