import Foundation

/// Fila de `resource_reservations`.
public struct Reservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let resourceId: UUID
    public let contextActorId: UUID
    public let requestedByActorId: UUID
    public let reservedForActorId: UUID?
    public let startsAt: Date
    public let endsAt: Date
    public let status: String
    public let priorityScore: Double?
    /// R.2T — link opcional Reservation → Event. Doctrina: una reservación
    /// puede asociarse a un evento sin que ninguno sea obligatorio del otro.
    public let sourceEventId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId = "resource_id"
        case contextActorId = "context_actor_id"
        case requestedByActorId = "requested_by_actor_id"
        case reservedForActorId = "reserved_for_actor_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case status
        case priorityScore = "priority_score"
        case sourceEventId = "source_event_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        resourceId: UUID,
        contextActorId: UUID,
        requestedByActorId: UUID,
        reservedForActorId: UUID? = nil,
        startsAt: Date,
        endsAt: Date,
        status: String = "requested",
        priorityScore: Double? = nil,
        sourceEventId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.resourceId = resourceId
        self.contextActorId = contextActorId
        self.requestedByActorId = requestedByActorId
        self.reservedForActorId = reservedForActorId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.priorityScore = priorityScore
        self.sourceEventId = sourceEventId
        self.createdAt = createdAt
    }

    public var statusLabel: String {
        switch status {
        case "requested": return "Solicitada"
        case "approved": return "Aprobada"
        case "confirmed": return "Confirmada"
        case "rejected": return "Rechazada"
        case "cancelled": return "Cancelada"
        case "completed": return "Completada"
        case "waitlisted": return "En lista de espera"
        default: return status
        }
    }

    public var isPending: Bool { status == "requested" }
    public var isActive: Bool { status == "approved" || status == "confirmed" }
}

/// Resultado de `request_resource_reservation()`.
public struct ReservationRequestResult: Decodable, Sendable, Equatable {
    public let reservationId: UUID
    public let conflictsDetected: Int
    public let reservation: Reservation?

    enum CodingKeys: String, CodingKey {
        case reservationId = "reservation_id"
        case conflictsDetected = "conflicts_detected"
        case reservation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.reservationId = try c.decode(UUID.self, forKey: .reservationId)
        self.conflictsDetected = try c.decodeIfPresent(Int.self, forKey: .conflictsDetected) ?? 0
        self.reservation = try c.decodeIfPresent(Reservation.self, forKey: .reservation)
    }

    public init(reservationId: UUID, conflictsDetected: Int = 0, reservation: Reservation? = nil) {
        self.reservationId = reservationId
        self.conflictsDetected = conflictsDetected
        self.reservation = reservation
    }
}

/// Fila de `reservation_conflicts`.
public struct ReservationConflict: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let resourceId: UUID
    public let reservationAId: UUID
    public let reservationBId: UUID
    public let conflictType: String
    public let resolutionStatus: String
    public let recommendedWinnerActorId: UUID?
    public let createdAt: Date?
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId = "resource_id"
        case reservationAId = "reservation_a_id"
        case reservationBId = "reservation_b_id"
        case conflictType = "conflict_type"
        case resolutionStatus = "resolution_status"
        case recommendedWinnerActorId = "recommended_winner_actor_id"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    public init(
        id: UUID,
        resourceId: UUID,
        reservationAId: UUID,
        reservationBId: UUID,
        conflictType: String = "overlap",
        resolutionStatus: String = "open",
        recommendedWinnerActorId: UUID? = nil,
        createdAt: Date? = nil,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.resourceId = resourceId
        self.reservationAId = reservationAId
        self.reservationBId = reservationBId
        self.conflictType = conflictType
        self.resolutionStatus = resolutionStatus
        self.recommendedWinnerActorId = recommendedWinnerActorId
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public var isOpen: Bool { resolutionStatus == "open" }
}

/// R.2S.7 — modelos de resolución para `resolve_reservation_conflict` (4-arg).
/// Algunos son sinónimos en backend pero los exponemos separados para UX.
public enum ResolutionModel: String, Sendable, Hashable, CaseIterable {
    /// El admin elige al ganador; el perdedor queda `rejected`.
    case winner
    /// Sinónimo de `winner` (priorización por orden / scoring).
    case priorityBased = "priority_based"
    /// Sinónimo de `winner` (override administrativo).
    case adminOverride = "admin_override"
    /// El backend escoge ganador al azar; perdedor `rejected`.
    case lottery
    /// Ganador `approved`, perdedor `waitlisted` (espera disponibilidad).
    case waitlisted
    /// Backend parte el rango por la mitad; ambas `approved`.
    case splitDates = "split_dates"
    /// Sinónimo de `split_dates`.
    case partialApproval = "partial_approval"
    /// Crea una decisión `reservation_dispute`; el conflicto queda `open` hasta
    /// que la decisión se ejecuta.
    case requiresDecision = "requires_decision"

    public var label: String {
        switch self {
        case .winner, .priorityBased, .adminOverride: return "Darle a un ganador"
        case .lottery: return "Sorteo aleatorio"
        case .waitlisted: return "Aprobar uno, otro en lista de espera"
        case .splitDates, .partialApproval: return "Partir las fechas"
        case .requiresDecision: return "Escalar a votación"
        }
    }

    /// Si el modelo requiere designar `winner_reservation_id`.
    public var requiresWinner: Bool {
        switch self {
        case .winner, .priorityBased, .adminOverride, .waitlisted: return true
        case .lottery, .splitDates, .partialApproval, .requiresDecision: return false
        }
    }
}

/// Resultado de `resolve_reservation_conflict` (4-arg). Forma variable según
/// el modelo: `lottery/winner/waitlisted` traen winner+loser; `split_dates`
/// trae `splitAt`; `requires_decision` trae `decisionId`.
public struct ResolveConflictResult: Decodable, Sendable, Equatable {
    public let conflictId: UUID
    public let resolutionModel: String
    public let resolutionStatus: String
    public let winnerReservationId: UUID?
    public let loserReservationId: UUID?
    /// Para `split_dates/partial_approval`: timestamp medio donde se cortó el rango.
    public let splitAt: Date?
    /// Para `requires_decision`: id de la decisión creada (el conflict queda abierto).
    public let decisionId: UUID?

    enum CodingKeys: String, CodingKey {
        case conflictId = "conflict_id"
        case resolutionModel = "resolution_model"
        case resolutionStatus = "resolution_status"
        case winnerReservationId = "winner_reservation_id"
        case loserReservationId = "loser_reservation_id"
        case splitAt = "split_at"
        case decisionId = "decision_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.conflictId = try c.decode(UUID.self, forKey: .conflictId)
        self.resolutionModel = try c.decodeIfPresent(String.self, forKey: .resolutionModel) ?? "winner"
        self.resolutionStatus = try c.decodeIfPresent(String.self, forKey: .resolutionStatus) ?? "resolved"
        self.winnerReservationId = try c.decodeIfPresent(UUID.self, forKey: .winnerReservationId)
        self.loserReservationId = try c.decodeIfPresent(UUID.self, forKey: .loserReservationId)
        self.splitAt = try c.decodeIfPresent(Date.self, forKey: .splitAt)
        self.decisionId = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
    }

    public init(
        conflictId: UUID,
        resolutionModel: String,
        resolutionStatus: String = "resolved",
        winnerReservationId: UUID? = nil,
        loserReservationId: UUID? = nil,
        splitAt: Date? = nil,
        decisionId: UUID? = nil
    ) {
        self.conflictId = conflictId
        self.resolutionModel = resolutionModel
        self.resolutionStatus = resolutionStatus
        self.winnerReservationId = winnerReservationId
        self.loserReservationId = loserReservationId
        self.splitAt = splitAt
        self.decisionId = decisionId
    }
}

/// R.2S — detalle de una reservación con `available_actions` canónicos
/// (`reservation_detail(p_reservation_id)`). El frontend renderiza los botones
/// (aprobar/confirmar/cancelar/resolver) desde aquí, no por status.
public struct ReservationDetail: Decodable, Sendable, Equatable {
    public let id: UUID
    public let resourceId: UUID
    public let contextActorId: UUID
    public let requestedByActorId: UUID
    public let reservedForActorId: UUID?
    public let startsAt: Date
    public let endsAt: Date
    public let status: String
    public let priorityScore: Double?
    public let sourceDecisionId: UUID?
    /// R.2T — link opcional Reservation → Event (calendar_events.id).
    public let sourceEventId: UUID?
    public let metadata: JSONValue?
    public let availableActions: [AvailableAction]
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId = "resource_id"
        case contextActorId = "context_actor_id"
        case requestedByActorId = "requested_by_actor_id"
        case reservedForActorId = "reserved_for_actor_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case status
        case priorityScore = "priority_score"
        case sourceDecisionId = "source_decision_id"
        case sourceEventId = "source_event_id"
        case metadata
        case availableActions = "available_actions"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.requestedByActorId = try c.decode(UUID.self, forKey: .requestedByActorId)
        self.reservedForActorId = try c.decodeIfPresent(UUID.self, forKey: .reservedForActorId)
        self.startsAt = try c.decode(Date.self, forKey: .startsAt)
        self.endsAt = try c.decode(Date.self, forKey: .endsAt)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "requested"
        self.priorityScore = try c.decodeIfPresent(Double.self, forKey: .priorityScore)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.sourceEventId = try c.decodeIfPresent(UUID.self, forKey: .sourceEventId)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public init(
        id: UUID,
        resourceId: UUID,
        contextActorId: UUID,
        requestedByActorId: UUID,
        reservedForActorId: UUID? = nil,
        startsAt: Date,
        endsAt: Date,
        status: String = "requested",
        priorityScore: Double? = nil,
        sourceDecisionId: UUID? = nil,
        sourceEventId: UUID? = nil,
        metadata: JSONValue? = nil,
        availableActions: [AvailableAction] = [],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.resourceId = resourceId
        self.contextActorId = contextActorId
        self.requestedByActorId = requestedByActorId
        self.reservedForActorId = reservedForActorId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.priorityScore = priorityScore
        self.sourceDecisionId = sourceDecisionId
        self.sourceEventId = sourceEventId
        self.metadata = metadata
        self.availableActions = availableActions
        self.createdAt = createdAt
    }

    public func action(_ key: String) -> AvailableAction? { availableActions.enabled(key) }
    public func can(_ key: String) -> Bool { availableActions.can(key) }
}
