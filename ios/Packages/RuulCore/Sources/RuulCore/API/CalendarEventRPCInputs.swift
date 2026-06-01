import Foundation

// V3-D.23 — Encodable parameter structs for the 11 calendar-event RPCs.
// Each property maps 1:1 to a `p_*` argument in the dev contract.

public struct CreateCalendarEventParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pTitle: String
    public let pDescription: String?
    public let pEventType: String
    public let pStartsAt: Date
    public let pEndsAt: Date?
    public let pTimezone: String?
    public let pLocationName: String?
    public let pLocationAddress: String?
    public let pLocationUrl: String?
    public let pRecurrenceRule: String?
    public let pVisibility: String
    public let pMetadata: [String: RPCJSONValue]?

    enum CodingKeys: String, CodingKey {
        case pGroupId         = "p_group_id"
        case pTitle           = "p_title"
        case pDescription     = "p_description"
        case pEventType       = "p_event_type"
        case pStartsAt        = "p_starts_at"
        case pEndsAt          = "p_ends_at"
        case pTimezone        = "p_timezone"
        case pLocationName    = "p_location_name"
        case pLocationAddress = "p_location_address"
        case pLocationUrl     = "p_location_url"
        case pRecurrenceRule  = "p_recurrence_rule"
        case pVisibility      = "p_visibility"
        case pMetadata        = "p_metadata"
    }
}

public struct UpdateCalendarEventParams: Encodable, Sendable {
    public let pEventId: UUID
    public let pTitle: String?
    public let pDescription: String?
    public let pEventType: String?
    public let pStartsAt: Date?
    public let pEndsAt: Date?
    public let pTimezone: String?
    public let pLocationName: String?
    public let pLocationAddress: String?
    public let pLocationUrl: String?
    public let pRecurrenceRule: String?
    public let pVisibility: String?
    public let pMetadata: [String: RPCJSONValue]?

    enum CodingKeys: String, CodingKey {
        case pEventId         = "p_event_id"
        case pTitle           = "p_title"
        case pDescription     = "p_description"
        case pEventType       = "p_event_type"
        case pStartsAt        = "p_starts_at"
        case pEndsAt          = "p_ends_at"
        case pTimezone        = "p_timezone"
        case pLocationName    = "p_location_name"
        case pLocationAddress = "p_location_address"
        case pLocationUrl     = "p_location_url"
        case pRecurrenceRule  = "p_recurrence_rule"
        case pVisibility      = "p_visibility"
        case pMetadata        = "p_metadata"
    }
}

public struct CancelCalendarEventParams: Encodable, Sendable {
    public let pEventId: UUID
    public let pReason: String?

    enum CodingKeys: String, CodingKey {
        case pEventId = "p_event_id"
        case pReason  = "p_reason"
    }
}

public struct ArchiveCalendarEventParams: Encodable, Sendable {
    public let pEventId: UUID
    enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
}

public struct ListGroupCalendarEventsParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pFrom: Date?
    public let pTo: Date?
    public let pIncludeCancelled: Bool
    public let pIncludeArchived: Bool

    enum CodingKeys: String, CodingKey {
        case pGroupId          = "p_group_id"
        case pFrom             = "p_from"
        case pTo               = "p_to"
        case pIncludeCancelled = "p_include_cancelled"
        case pIncludeArchived  = "p_include_archived"
    }
}

public struct GetCalendarEventDetailParams: Encodable, Sendable {
    public let pEventId: UUID
    enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
}

public struct AddCalendarEventAttendeeParams: Encodable, Sendable {
    public let pEventId: UUID
    public let pMembershipId: UUID?
    public let pInvitedEmail: String?
    public let pInvitedPhone: String?
    public let pDisplayName: String?
    public let pRole: String

    enum CodingKeys: String, CodingKey {
        case pEventId      = "p_event_id"
        case pMembershipId = "p_membership_id"
        case pInvitedEmail = "p_invited_email"
        case pInvitedPhone = "p_invited_phone"
        case pDisplayName  = "p_display_name"
        case pRole         = "p_role"
    }
}

public struct RemoveCalendarEventAttendeeParams: Encodable, Sendable {
    public let pEventAttendeeId: UUID
    enum CodingKeys: String, CodingKey { case pEventAttendeeId = "p_event_attendee_id" }
}

public struct RespondCalendarEventParams: Encodable, Sendable {
    public let pEventId: UUID
    public let pRsvpStatus: String
    public let pRsvpNote: String?

    enum CodingKeys: String, CodingKey {
        case pEventId   = "p_event_id"
        case pRsvpStatus = "p_rsvp_status"
        case pRsvpNote   = "p_rsvp_note"
    }
}

public struct AddCalendarEventReminderParams: Encodable, Sendable {
    public let pEventId: UUID
    public let pReminderType: String
    public let pOffsetMinutes: Int
    public let pTarget: String
    public let pTargetMembershipId: UUID?

    enum CodingKeys: String, CodingKey {
        case pEventId            = "p_event_id"
        case pReminderType       = "p_reminder_type"
        case pOffsetMinutes      = "p_offset_minutes"
        case pTarget             = "p_target"
        case pTargetMembershipId = "p_target_membership_id"
    }
}

public struct RemoveCalendarEventReminderParams: Encodable, Sendable {
    public let pReminderId: UUID
    enum CodingKeys: String, CodingKey { case pReminderId = "p_reminder_id" }
}
