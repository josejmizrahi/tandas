import Foundation

/// V3-D.23 — Calendar Event primitive. Mirrors `public.group_calendar_events`
/// plus the projection returned by `list_group_events(...)` and the wrapper
/// `get_event_detail(...)`.
///
/// Decoupled from the existing `GroupEvent` domain (which represents
/// `public.group_events` — the append-only audit log). UI strings stay in
/// Spanish ("Evento", "Próximos eventos"); only the Swift identifiers
/// carry the `CalendarEvent` prefix to disambiguate.
public enum CalendarEventType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case social
    case meal
    case meetingCandidate = "meeting_candidate"
    case ceremony
    case workSession      = "work_session"
    case deadline
    case maintenance
    case trip
    case ritual
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .social:            return "Social"
        case .meal:              return "Comida"
        case .meetingCandidate:  return "Posible reunión"
        case .ceremony:          return "Ceremonia"
        case .workSession:       return "Sesión de trabajo"
        case .deadline:          return "Fecha límite"
        case .maintenance:       return "Mantenimiento"
        case .trip:              return "Viaje"
        case .ritual:            return "Ritual"
        case .other:             return "Otro"
        }
    }

    public var systemImageName: String {
        switch self {
        case .social:            return "person.2.fill"
        case .meal:              return "fork.knife"
        case .meetingCandidate:  return "bubble.left.and.bubble.right.fill"
        case .ceremony:          return "sparkles"
        case .workSession:       return "hammer.fill"
        case .deadline:          return "flag.fill"
        case .maintenance:       return "wrench.adjustable.fill"
        case .trip:              return "airplane"
        case .ritual:            return "moon.stars.fill"
        case .other:             return "calendar"
        }
    }
}

public enum CalendarEventStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case scheduled
    case cancelled
    case completed
    case archived

    public var label: String {
        switch self {
        case .scheduled: return "Programado"
        case .cancelled: return "Cancelado"
        case .completed: return "Completado"
        case .archived:  return "Archivado"
        }
    }
}

public enum CalendarEventVisibility: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case group
    case invited
    case admins
    case publicLink = "public_link"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .group:      return "Todo el grupo"
        case .invited:    return "Sólo invitados"
        case .admins:     return "Sólo admins"
        case .publicLink: return "Enlace público"
        }
    }
}

public enum CalendarEventAttendeeRole: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case host
    case cohost
    case attendee
    case optional
    case observer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .host:     return "Anfitrión"
        case .cohost:   return "Co-anfitrión"
        case .attendee: return "Asistente"
        case .optional: return "Opcional"
        case .observer: return "Observador"
        }
    }
}

public enum CalendarEventRSVPStatus: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case pending
    case accepted
    case declined
    case tentative
    case maybe

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pending:   return "Pendiente"
        case .accepted:  return "Acepto"
        case .declined:  return "No puedo"
        case .tentative: return "Tentativo"
        case .maybe:     return "Tal vez"
        }
    }

    public var systemImageName: String {
        switch self {
        case .pending:   return "questionmark.circle"
        case .accepted:  return "checkmark.circle.fill"
        case .declined:  return "xmark.circle.fill"
        case .tentative: return "hourglass"
        case .maybe:     return "ellipsis.circle"
        }
    }
}

public enum CalendarEventReminderType: String, Codable, CaseIterable, Sendable, Hashable {
    case push
    case email
    case sms
    case inbox
    case noop
}

public enum CalendarEventReminderTarget: String, Codable, CaseIterable, Sendable, Hashable {
    case attendees
    case hosts
    case allMembers          = "all_members"
    case specificMembership  = "specific_membership"
}

// MARK: - List item (from list_group_events)

public struct CalendarEventListItem: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let description: String?
    public let eventType: CalendarEventType
    public let startsAt: Date
    public let endsAt: Date?
    public let timezone: String?
    public let locationName: String?
    public let locationAddress: String?
    public let locationUrl: String?
    public let recurrenceRule: String?
    public let recurrenceParentId: UUID?
    public let visibility: CalendarEventVisibility
    public let status: CalendarEventStatus
    public let metadata: [String: RPCJSONValue]?
    public let createdBy: UUID?
    public let createdAt: Date?
    public let archivedAt: Date?
    public let attendeeCount: Int
    public let acceptedCount: Int
    public let myRsvpStatus: CalendarEventRSVPStatus?
    public let myAttendeeRole: CalendarEventAttendeeRole?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId            = "group_id"
        case title
        case description
        case eventType          = "event_type"
        case startsAt           = "starts_at"
        case endsAt             = "ends_at"
        case timezone
        case locationName       = "location_name"
        case locationAddress    = "location_address"
        case locationUrl        = "location_url"
        case recurrenceRule     = "recurrence_rule"
        case recurrenceParentId = "recurrence_parent_id"
        case visibility
        case status
        case metadata
        case createdBy          = "created_by"
        case createdAt          = "created_at"
        case archivedAt         = "archived_at"
        case attendeeCount      = "attendee_count"
        case acceptedCount      = "accepted_count"
        case myRsvpStatus       = "my_rsvp_status"
        case myAttendeeRole     = "my_attendee_role"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.groupId         = try c.decode(UUID.self, forKey: .groupId)
        self.title           = try c.decode(String.self, forKey: .title)
        self.description     = try c.decodeIfPresent(String.self, forKey: .description)
        let rawType          = try c.decode(String.self, forKey: .eventType)
        self.eventType       = CalendarEventType(rawValue: rawType) ?? .other
        self.startsAt        = try c.decode(Date.self, forKey: .startsAt)
        self.endsAt          = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        self.timezone        = try c.decodeIfPresent(String.self, forKey: .timezone)
        self.locationName    = try c.decodeIfPresent(String.self, forKey: .locationName)
        self.locationAddress = try c.decodeIfPresent(String.self, forKey: .locationAddress)
        self.locationUrl     = try c.decodeIfPresent(String.self, forKey: .locationUrl)
        self.recurrenceRule  = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        self.recurrenceParentId = try c.decodeIfPresent(UUID.self, forKey: .recurrenceParentId)
        let rawVis           = try c.decode(String.self, forKey: .visibility)
        self.visibility      = CalendarEventVisibility(rawValue: rawVis) ?? .group
        let rawStatus        = try c.decode(String.self, forKey: .status)
        self.status          = CalendarEventStatus(rawValue: rawStatus) ?? .scheduled
        self.metadata        = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .metadata)
        self.createdBy       = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.archivedAt      = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.attendeeCount   = try c.decodeIfPresent(Int.self, forKey: .attendeeCount) ?? 0
        self.acceptedCount   = try c.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
        if let raw = try c.decodeIfPresent(String.self, forKey: .myRsvpStatus) {
            self.myRsvpStatus = CalendarEventRSVPStatus(rawValue: raw)
        } else {
            self.myRsvpStatus = nil
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .myAttendeeRole) {
            self.myAttendeeRole = CalendarEventAttendeeRole(rawValue: raw)
        } else {
            self.myAttendeeRole = nil
        }
    }
}

// MARK: - Detail (from get_event_detail)

public struct CalendarEventAttendee: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let membershipId: UUID?
    public let invitedEmail: String?
    public let invitedPhone: String?
    public let displayName: String?
    public let role: CalendarEventAttendeeRole
    public let rsvpStatus: CalendarEventRSVPStatus
    public let rsvpNote: String?
    public let respondedAt: Date?
    public let createdAt: Date?
    public let userId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case membershipId = "membership_id"
        case invitedEmail = "invited_email"
        case invitedPhone = "invited_phone"
        case displayName  = "display_name"
        case role
        case rsvpStatus   = "rsvp_status"
        case rsvpNote     = "rsvp_note"
        case respondedAt  = "responded_at"
        case createdAt    = "created_at"
        case userId       = "user_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self, forKey: .id)
        self.membershipId = try c.decodeIfPresent(UUID.self, forKey: .membershipId)
        self.invitedEmail = try c.decodeIfPresent(String.self, forKey: .invitedEmail)
        self.invitedPhone = try c.decodeIfPresent(String.self, forKey: .invitedPhone)
        self.displayName  = try c.decodeIfPresent(String.self, forKey: .displayName)
        let rawRole       = try c.decodeIfPresent(String.self, forKey: .role) ?? "attendee"
        self.role         = CalendarEventAttendeeRole(rawValue: rawRole) ?? .attendee
        let rawRsvp       = try c.decodeIfPresent(String.self, forKey: .rsvpStatus) ?? "pending"
        self.rsvpStatus   = CalendarEventRSVPStatus(rawValue: rawRsvp) ?? .pending
        self.rsvpNote     = try c.decodeIfPresent(String.self, forKey: .rsvpNote)
        self.respondedAt  = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        self.createdAt    = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.userId       = try c.decodeIfPresent(UUID.self, forKey: .userId)
    }
}

public struct CalendarEventReminder: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let reminderType: CalendarEventReminderType
    public let offsetMinutes: Int
    public let target: CalendarEventReminderTarget
    public let targetMembershipId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case reminderType       = "reminder_type"
        case offsetMinutes      = "offset_minutes"
        case target
        case targetMembershipId = "target_membership_id"
        case createdAt          = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self, forKey: .id)
        let rawType        = try c.decodeIfPresent(String.self, forKey: .reminderType) ?? "push"
        self.reminderType  = CalendarEventReminderType(rawValue: rawType) ?? .push
        self.offsetMinutes = try c.decode(Int.self, forKey: .offsetMinutes)
        let rawTarget      = try c.decodeIfPresent(String.self, forKey: .target) ?? "attendees"
        self.target        = CalendarEventReminderTarget(rawValue: rawTarget) ?? .attendees
        self.targetMembershipId = try c.decodeIfPresent(UUID.self, forKey: .targetMembershipId)
        self.createdAt     = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public struct CalendarEventPermissions: Codable, Equatable, Sendable, Hashable {
    public let canUpdate: Bool
    public let canCancel: Bool
    public let canArchive: Bool
    public let canManageAttendees: Bool
    public let canManageReminders: Bool
    public let canRsvp: Bool

    enum CodingKeys: String, CodingKey {
        case canUpdate          = "can_update"
        case canCancel          = "can_cancel"
        case canArchive         = "can_archive"
        case canManageAttendees = "can_manage_attendees"
        case canManageReminders = "can_manage_reminders"
        case canRsvp            = "can_rsvp"
    }
}

public struct CalendarEvent: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let description: String?
    public let eventType: CalendarEventType
    public let startsAt: Date
    public let endsAt: Date?
    public let timezone: String?
    public let locationName: String?
    public let locationAddress: String?
    public let locationUrl: String?
    public let recurrenceRule: String?
    public let recurrenceParentId: UUID?
    public let visibility: CalendarEventVisibility
    public let status: CalendarEventStatus
    public let metadata: [String: RPCJSONValue]?
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId            = "group_id"
        case title
        case description
        case eventType          = "event_type"
        case startsAt           = "starts_at"
        case endsAt             = "ends_at"
        case timezone
        case locationName       = "location_name"
        case locationAddress    = "location_address"
        case locationUrl        = "location_url"
        case recurrenceRule     = "recurrence_rule"
        case recurrenceParentId = "recurrence_parent_id"
        case visibility
        case status
        case metadata
        case createdBy          = "created_by"
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
        case archivedAt         = "archived_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.groupId         = try c.decode(UUID.self, forKey: .groupId)
        self.title           = try c.decode(String.self, forKey: .title)
        self.description     = try c.decodeIfPresent(String.self, forKey: .description)
        let rawType          = try c.decode(String.self, forKey: .eventType)
        self.eventType       = CalendarEventType(rawValue: rawType) ?? .other
        self.startsAt        = try c.decode(Date.self, forKey: .startsAt)
        self.endsAt          = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        self.timezone        = try c.decodeIfPresent(String.self, forKey: .timezone)
        self.locationName    = try c.decodeIfPresent(String.self, forKey: .locationName)
        self.locationAddress = try c.decodeIfPresent(String.self, forKey: .locationAddress)
        self.locationUrl     = try c.decodeIfPresent(String.self, forKey: .locationUrl)
        self.recurrenceRule  = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        self.recurrenceParentId = try c.decodeIfPresent(UUID.self, forKey: .recurrenceParentId)
        let rawVis           = try c.decode(String.self, forKey: .visibility)
        self.visibility      = CalendarEventVisibility(rawValue: rawVis) ?? .group
        let rawStatus        = try c.decode(String.self, forKey: .status)
        self.status          = CalendarEventStatus(rawValue: rawStatus) ?? .scheduled
        self.metadata        = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .metadata)
        self.createdBy       = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt       = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.archivedAt      = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

public struct CalendarEventDetail: Codable, Equatable, Sendable, Hashable {
    public let event: CalendarEvent
    public let attendees: [CalendarEventAttendee]
    public let reminders: [CalendarEventReminder]
    public let permissions: CalendarEventPermissions
    public let callerMembershipId: UUID?

    enum CodingKeys: String, CodingKey {
        case event
        case attendees
        case reminders
        case permissions
        case callerMembershipId = "caller_membership_id"
    }
}

/// V3 D.24 P12A — payload of `event_detail_summary(p_event_id)` RPC.
/// Strict superset of `CalendarEventDetail` (wraps `get_event_detail`)
/// + `comments_count` + `attachments_count`. iOS adopt iniciado en
/// P12B-3 — `CalendarEventDetailView` prefiere este shape y cae a
/// `loadDetail` legacy si la RPC summary falla.
public struct CalendarEventDetailSummary: Codable, Equatable, Sendable, Hashable {
    public let event: CalendarEvent
    public let attendees: [CalendarEventAttendee]
    public let reminders: [CalendarEventReminder]
    public let permissions: CalendarEventPermissions
    public let callerMembershipId: UUID?
    public let commentsCount: Int
    public let attachmentsCount: Int

    enum CodingKeys: String, CodingKey {
        case event
        case attendees
        case reminders
        case permissions
        case callerMembershipId = "caller_membership_id"
        case commentsCount      = "comments_count"
        case attachmentsCount   = "attachments_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.event              = try c.decode(CalendarEvent.self, forKey: .event)
        self.attendees          = try c.decodeIfPresent([CalendarEventAttendee].self, forKey: .attendees) ?? []
        self.reminders          = try c.decodeIfPresent([CalendarEventReminder].self, forKey: .reminders) ?? []
        self.permissions        = try c.decode(CalendarEventPermissions.self, forKey: .permissions)
        self.callerMembershipId = try c.decodeIfPresent(UUID.self, forKey: .callerMembershipId)
        self.commentsCount      = try c.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        self.attachmentsCount   = try c.decodeIfPresent(Int.self, forKey: .attachmentsCount) ?? 0
    }

    /// Bridge para call-sites que ya consumían `CalendarEventDetail`.
    /// Permite render unificado en `CalendarEventDetailView` (la vista
    /// chequea summary first; si está nil, sigue su path legacy).
    public var asDetail: CalendarEventDetail {
        CalendarEventDetail(
            event: event,
            attendees: attendees,
            reminders: reminders,
            permissions: permissions,
            callerMembershipId: callerMembershipId
        )
    }
}

// MARK: - Light recurrence DSL (UI helper)

public enum CalendarEventRecurrenceKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case none
    case weekly
    case monthly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none:    return "No se repite"
        case .weekly:  return "Cada semana"
        case .monthly: return "Cada mes"
        }
    }

    /// Translate the UI choice into an RRULE-ish string that lives in
    /// `group_calendar_events.recurrence_rule`. The backend doesn't
    /// expand instances yet (D.23), but storing a canonical token now
    /// keeps the door open for a real RRULE expander later.
    public func rruleText(weekday: Int? = nil, day: Int? = nil) -> String? {
        switch self {
        case .none:
            return nil
        case .weekly:
            let days = ["SU","MO","TU","WE","TH","FR","SA"]
            let idx = (weekday.map { (($0 - 1) % 7 + 7) % 7 }) ?? 5  // default FR
            return "FREQ=WEEKLY;BYDAY=\(days[idx])"
        case .monthly:
            return "FREQ=MONTHLY" + (day.map { ";BYMONTHDAY=\($0)" } ?? "")
        }
    }
}
