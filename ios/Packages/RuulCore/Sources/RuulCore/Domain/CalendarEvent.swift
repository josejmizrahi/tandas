import Foundation

// MARK: - Tipos

public enum EventType: String, Codable, Sendable, CaseIterable, Identifiable {
    case dinner, meeting, trip
    case gameNight = "game_night"
    case communityEvent = "community_event"
    case deadline, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dinner: return "Cena"
        case .meeting: return "Reunión"
        case .trip: return "Viaje"
        case .gameNight: return "Noche de juegos"
        case .communityEvent: return "Evento comunitario"
        case .deadline: return "Fecha límite"
        case .other: return "Otro"
        }
    }

    public var symbolName: String {
        switch self {
        case .dinner: return "fork.knife"
        case .meeting: return "person.2.fill"
        case .trip: return "airplane"
        case .gameNight: return "dice.fill"
        case .communityEvent: return "person.3.fill"
        case .deadline: return "clock.badge.exclamationmark"
        case .other: return "calendar"
        }
    }
}

public enum RSVPStatus: String, Codable, Sendable {
    case going, maybe, declined
}

public enum ParticipantStatus: String, Codable, Sendable {
    case invited, going, maybe, declined, cancelled, attended, late
    case noShow = "no_show"

    public var label: String {
        switch self {
        case .invited: return "Invitado"
        case .going: return "Va"
        case .maybe: return "Tal vez"
        case .declined: return "No va"
        case .cancelled: return "Canceló"
        case .attended: return "Asistió"
        case .late: return "Llegó tarde"
        case .noShow: return "No llegó"
        }
    }
}

// MARK: - CalendarEvent (fila de `calendar_events`)

public struct CalendarEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
    public let title: String
    public let description: String?
    public let eventType: String
    public let startsAt: Date?
    public let endsAt: Date?
    public let timezone: String?
    public let locationText: String?
    /// F.EVENT.5 — el evento es virtual (Zoom, Meet, etc.) y por eso NO
    /// requiere ubicación física. Por default `false`. El backend enforza:
    /// si `is_virtual = false` entonces `location_text` es obligatorio
    /// (CHECK constraint + RPC validation).
    public let isVirtual: Bool
    public let recurrenceRule: String?
    public let hostActorId: UUID?
    public let status: String
    public let createdByActorId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case title
        case description
        case eventType = "event_type"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case timezone
        case locationText = "location_text"
        case isVirtual = "is_virtual"
        case recurrenceRule = "recurrence_rule"
        case hostActorId = "host_actor_id"
        case status
        case createdByActorId = "created_by_actor_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID,
        title: String,
        description: String? = nil,
        eventType: String,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        timezone: String? = nil,
        locationText: String? = nil,
        isVirtual: Bool = false,
        recurrenceRule: String? = nil,
        hostActorId: UUID? = nil,
        status: String = "scheduled",
        createdByActorId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.title = title
        self.description = description
        self.eventType = eventType
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timezone = timezone
        self.locationText = locationText
        self.isVirtual = isVirtual
        self.recurrenceRule = recurrenceRule
        self.hostActorId = hostActorId
        self.status = status
        self.createdByActorId = createdByActorId
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.eventType = try c.decode(String.self, forKey: .eventType)
        self.startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        self.endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        self.timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        self.locationText = try c.decodeIfPresent(String.self, forKey: .locationText)
        // F.EVENT.5 — viejos shapes pueden no traer is_virtual, default false.
        self.isVirtual = try c.decodeIfPresent(Bool.self, forKey: .isVirtual) ?? false
        self.recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        self.hostActorId = try c.decodeIfPresent(UUID.self, forKey: .hostActorId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "scheduled"
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var type: EventType { EventType(rawValue: eventType) ?? .other }
    public var isScheduled: Bool { status == "scheduled" }
    public var isCompleted: Bool { status == "completed" }
    public var isRecurring: Bool { recurrenceRule != nil }
}

/// Resultado de `create_calendar_event()`.
public struct EventCreated: Decodable, Sendable, Equatable {
    public let eventId: UUID
    public let event: CalendarEvent
    public let participants: Int?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case event
        case participants
    }
}

/// F.2X.0 — Detalle canónico de un evento (`event_detail(p_event_id)`).
/// Mismo shape que `resource_detail` / `decision_detail` / `reservation_detail`
/// / `obligation_detail`: event + participants[] + available_actions[] +
/// capabilities[] + why_visible[].
public struct EventDetail: Decodable, Sendable, Equatable {
    public let event: CalendarEvent
    public let participants: [EventParticipant]
    public let availableActions: [AvailableAction]
    public let capabilities: [String]
    public let whyVisible: [String]

    enum CodingKeys: String, CodingKey {
        case event
        case participants
        case availableActions = "available_actions"
        case capabilities
        case whyVisible = "why_visible"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.event = try c.decode(CalendarEvent.self, forKey: .event)
        self.participants = try c.decodeIfPresent([EventParticipant].self, forKey: .participants) ?? []
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.whyVisible = try c.decodeIfPresent([String].self, forKey: .whyVisible) ?? []
    }

    public init(
        event: CalendarEvent,
        participants: [EventParticipant] = [],
        availableActions: [AvailableAction] = [],
        capabilities: [String] = [],
        whyVisible: [String] = []
    ) {
        self.event = event
        self.participants = participants
        self.availableActions = availableActions
        self.capabilities = capabilities
        self.whyVisible = whyVisible
    }

    public func can(_ actionKey: String) -> Bool { availableActions.can(actionKey) }
    public func action(_ actionKey: String) -> AvailableAction? { availableActions.enabled(actionKey) }
}

// MARK: - Participantes (fila de `event_participants`)

public struct EventParticipant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let eventId: UUID
    public let participantActorId: UUID
    public let status: String
    public let rsvpAt: Date?
    public let checkedInAt: Date?
    public let cancelledAt: Date?
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case participantActorId = "participant_actor_id"
        case status
        case rsvpAt = "rsvp_at"
        case checkedInAt = "checked_in_at"
        case cancelledAt = "cancelled_at"
        case metadata
    }

    public init(
        id: UUID,
        eventId: UUID,
        participantActorId: UUID,
        status: String = "invited",
        rsvpAt: Date? = nil,
        checkedInAt: Date? = nil,
        cancelledAt: Date? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.participantActorId = participantActorId
        self.status = status
        self.rsvpAt = rsvpAt
        self.checkedInAt = checkedInAt
        self.cancelledAt = cancelledAt
        self.metadata = metadata
    }

    public var participantStatus: ParticipantStatus? { ParticipantStatus(rawValue: status) }
    public var statusLabel: String { participantStatus?.label ?? status }
    public var minutesLate: Double? { metadata?["minutes_late"]?.numberValue }
    public var checkedIn: Bool { checkedInAt != nil }
}

// MARK: - Resultados de acciones

/// Resultado de `check_in_participant()`.
public struct CheckInResult: Decodable, Sendable, Equatable {
    public let participantId: UUID
    public let status: String
    public let checkedInAt: Date?
    public let minutesLate: Double?
    public let alreadyCheckedIn: Bool

    enum CodingKeys: String, CodingKey {
        case participantId = "participant_id"
        case status
        case checkedInAt = "checked_in_at"
        case minutesLate = "minutes_late"
        case alreadyCheckedIn = "already_checked_in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.participantId = try c.decode(UUID.self, forKey: .participantId)
        self.status = try c.decode(String.self, forKey: .status)
        self.checkedInAt = try c.decodeIfPresent(Date.self, forKey: .checkedInAt)
        self.minutesLate = try c.decodeIfPresent(Double.self, forKey: .minutesLate)
        self.alreadyCheckedIn = try c.decodeIfPresent(Bool.self, forKey: .alreadyCheckedIn) ?? false
    }

    public init(participantId: UUID, status: String, checkedInAt: Date? = nil, minutesLate: Double? = nil, alreadyCheckedIn: Bool = false) {
        self.participantId = participantId
        self.status = status
        self.checkedInAt = checkedInAt
        self.minutesLate = minutesLate
        self.alreadyCheckedIn = alreadyCheckedIn
    }

    public var isLate: Bool { status == "late" }
}

/// Resultado de `cancel_participation()`.
public struct CancelParticipationResult: Decodable, Sendable, Equatable {
    public let participantId: UUID
    public let status: String
    public let sameDayCancellation: Bool
    public let alreadyCancelled: Bool

    enum CodingKeys: String, CodingKey {
        case participantId = "participant_id"
        case status
        case sameDayCancellation = "same_day_cancellation"
        case alreadyCancelled = "already_cancelled"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.participantId = try c.decode(UUID.self, forKey: .participantId)
        self.status = try c.decode(String.self, forKey: .status)
        self.sameDayCancellation = try c.decodeIfPresent(Bool.self, forKey: .sameDayCancellation) ?? false
        self.alreadyCancelled = try c.decodeIfPresent(Bool.self, forKey: .alreadyCancelled) ?? false
    }

    public init(participantId: UUID, status: String = "cancelled", sameDayCancellation: Bool = false, alreadyCancelled: Bool = false) {
        self.participantId = participantId
        self.status = status
        self.sameDayCancellation = sameDayCancellation
        self.alreadyCancelled = alreadyCancelled
    }
}

/// Resultado de `close_event()`.
public struct CloseEventResult: Decodable, Sendable, Equatable {
    public let eventId: UUID
    public let status: String
    public let noShows: Int?
    public let nextEventId: UUID?
    public let nextHostActorId: UUID?
    public let alreadyClosed: Bool

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case status
        case noShows = "no_shows"
        case nextEventId = "next_event_id"
        case nextHostActorId = "next_host_actor_id"
        case alreadyClosed = "already_closed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.eventId = try c.decode(UUID.self, forKey: .eventId)
        self.status = try c.decode(String.self, forKey: .status)
        self.noShows = try c.decodeIfPresent(Int.self, forKey: .noShows)
        self.nextEventId = try c.decodeIfPresent(UUID.self, forKey: .nextEventId)
        self.nextHostActorId = try c.decodeIfPresent(UUID.self, forKey: .nextHostActorId)
        self.alreadyClosed = try c.decodeIfPresent(Bool.self, forKey: .alreadyClosed) ?? false
    }

    public init(eventId: UUID, status: String = "completed", noShows: Int? = nil, nextEventId: UUID? = nil, nextHostActorId: UUID? = nil, alreadyClosed: Bool = false) {
        self.eventId = eventId
        self.status = status
        self.noShows = noShows
        self.nextEventId = nextEventId
        self.nextHostActorId = nextHostActorId
        self.alreadyClosed = alreadyClosed
    }
}
