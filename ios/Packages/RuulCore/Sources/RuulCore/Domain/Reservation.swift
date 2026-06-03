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
        self.metadata = metadata
        self.availableActions = availableActions
        self.createdAt = createdAt
    }

    public func action(_ key: String) -> AvailableAction? { availableActions.enabled(key) }
    public func can(_ key: String) -> Bool { availableActions.can(key) }
}
