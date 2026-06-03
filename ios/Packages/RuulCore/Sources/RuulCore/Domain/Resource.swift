import Foundation

// MARK: - Tipos

public enum ResourceType: String, Codable, Sendable, CaseIterable, Identifiable {
    case property, house, vehicle
    case bankAccount = "bank_account"
    case cashPool = "cash_pool"
    case contract, document, reservation
    case tripBooking = "trip_booking"
    case game, equipment, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .property: return "Propiedad"
        case .house: return "Casa"
        case .vehicle: return "Vehículo"
        case .bankAccount: return "Cuenta bancaria"
        case .cashPool: return "Fondo común"
        case .contract: return "Contrato"
        case .document: return "Documento"
        case .reservation: return "Reservación"
        case .tripBooking: return "Reserva de viaje"
        case .game: return "Juego"
        case .equipment: return "Equipo"
        case .other: return "Otro"
        }
    }

    public var symbolName: String {
        switch self {
        case .property, .house: return "house.fill"
        case .vehicle: return "car.fill"
        case .bankAccount: return "banknote"
        case .cashPool: return "dollarsign.circle.fill"
        case .contract, .document: return "doc.text.fill"
        case .reservation: return "calendar.badge.clock"
        case .tripBooking: return "airplane"
        case .game: return "dice.fill"
        case .equipment: return "wrench.and.screwdriver.fill"
        case .other: return "shippingbox.fill"
        }
    }
}

/// Derechos sobre recursos (whitelist de `resource_rights.right_kind`).
public enum RightKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case own = "OWN"
    case use = "USE"
    case manage = "MANAGE"
    case view = "VIEW"
    case sell = "SELL"
    case transfer = "TRANSFER"
    case govern = "GOVERN"
    case beneficiary = "BENEFICIARY"
    case lien = "LIEN"
    case lease = "LEASE"
    case approve = "APPROVE"
    case audit = "AUDIT"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .own: return "Dueño"
        case .use: return "Puede usar"
        case .manage: return "Administra"
        case .view: return "Puede ver"
        case .sell: return "Puede vender"
        case .transfer: return "Puede transferir"
        case .govern: return "Gobierna"
        case .beneficiary: return "Beneficiario"
        case .lien: return "Gravamen"
        case .lease: return "Arrendatario"
        case .approve: return "Aprueba"
        case .audit: return "Audita"
        }
    }

    /// Derechos que permiten solicitar reservaciones del recurso.
    public var allowsReservation: Bool {
        switch self {
        case .own, .use, .manage, .govern, .lease: return true
        case .view, .sell, .transfer, .beneficiary, .lien, .approve, .audit: return false
        }
    }
}

// MARK: - Resource (fila de `resources`)

public struct Resource: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let resourceType: String
    public let displayName: String
    public let description: String?
    public let status: String
    public let estimatedValue: Double?
    public let currency: String?
    public let canonicalOwnerActorId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resourceType = "resource_type"
        case displayName = "display_name"
        case description
        case status
        case estimatedValue = "estimated_value"
        case currency
        case canonicalOwnerActorId = "canonical_owner_actor_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        resourceType: String,
        displayName: String,
        description: String? = nil,
        status: String = "active",
        estimatedValue: Double? = nil,
        currency: String? = nil,
        canonicalOwnerActorId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.resourceType = resourceType
        self.displayName = displayName
        self.description = description
        self.status = status
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.canonicalOwnerActorId = canonicalOwnerActorId
        self.createdAt = createdAt
    }

    public var type: ResourceType { ResourceType(rawValue: resourceType) ?? .other }
}

/// Resultado de `create_resource()` / `update_resource()`.
public struct ResourceCreated: Decodable, Sendable, Equatable {
    public let resourceId: UUID
    public let resource: Resource

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case resource
    }
}

// MARK: - Rights

/// Un derecho activo sobre un recurso (de `resource_detail().rights` /
/// `list_context_resources().rights`).
public struct ResourceRight: Codable, Sendable, Equatable, Identifiable {
    public let rightId: UUID
    public let holderActorId: UUID
    public let holderDisplayName: String?
    public let rightKind: String
    public let percent: Double?
    public let scope: String?
    public let startsAt: Date?
    public let endsAt: Date?

    enum CodingKeys: String, CodingKey {
        case rightId = "right_id"
        case holderActorId = "holder_actor_id"
        case holderDisplayName = "holder_display_name"
        case rightKind = "right_kind"
        case percent
        case scope
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    public init(
        rightId: UUID,
        holderActorId: UUID,
        holderDisplayName: String? = nil,
        rightKind: String,
        percent: Double? = nil,
        scope: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil
    ) {
        self.rightId = rightId
        self.holderActorId = holderActorId
        self.holderDisplayName = holderDisplayName
        self.rightKind = rightKind
        self.percent = percent
        self.scope = scope
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public var id: UUID { rightId }
    public var kind: RightKind? { RightKind(rawValue: rightKind) }
    public var kindLabel: String { kind?.label ?? rightKind }
}

/// Detalle completo: recurso + derechos activos (de `resource_detail()`).
public struct ResourceDetail: Decodable, Sendable, Equatable {
    public let resource: Resource
    public let rights: [ResourceRight]

    enum CodingKeys: String, CodingKey {
        case resource
        case rights
    }

    public init(resource: Resource, rights: [ResourceRight] = []) {
        self.resource = resource
        self.rights = rights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resource = try c.decode(Resource.self, forKey: .resource)
        self.rights = try c.decodeIfPresent([ResourceRight].self, forKey: .rights) ?? []
    }

    /// Razones por las que un actor ve este recurso ("Por qué aparece aquí").
    public func reasons(for actorId: UUID) -> [ResourceRight] {
        rights.filter { $0.holderActorId == actorId }
    }
}

/// Un elemento de `list_context_resources()`.
public struct ContextResource: Codable, Sendable, Equatable, Identifiable {
    public let resourceId: UUID
    public let resourceType: String
    public let displayName: String
    public let status: String
    public let estimatedValue: Double?
    public let currency: String?
    public let canonicalOwnerActorId: UUID?
    public let rights: [ResourceRight]

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case resourceType = "resource_type"
        case displayName = "display_name"
        case status
        case estimatedValue = "estimated_value"
        case currency
        case canonicalOwnerActorId = "canonical_owner_actor_id"
        case rights
    }

    public init(
        resourceId: UUID,
        resourceType: String,
        displayName: String,
        status: String = "active",
        estimatedValue: Double? = nil,
        currency: String? = nil,
        canonicalOwnerActorId: UUID? = nil,
        rights: [ResourceRight] = []
    ) {
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.displayName = displayName
        self.status = status
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.canonicalOwnerActorId = canonicalOwnerActorId
        self.rights = rights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.resourceType = try c.decode(String.self, forKey: .resourceType)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.estimatedValue = try c.decodeIfPresent(Double.self, forKey: .estimatedValue)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.canonicalOwnerActorId = try c.decodeIfPresent(UUID.self, forKey: .canonicalOwnerActorId)
        self.rights = try c.decodeIfPresent([ResourceRight].self, forKey: .rights) ?? []
    }

    public var id: UUID { resourceId }
    public var type: ResourceType { ResourceType(rawValue: resourceType) ?? .other }
}
