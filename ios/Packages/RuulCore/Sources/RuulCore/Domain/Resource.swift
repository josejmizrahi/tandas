import Foundation

// MARK: - Tipos

public enum ResourceType: String, Codable, Sendable, CaseIterable, Identifiable {
    case property, house, vehicle, security
    case bankAccount = "bank_account"
    case cashPool = "cash_pool"
    case contract, document, reservation
    case tripBooking = "trip_booking"
    case trustAsset = "trust_asset"
    case digitalAsset = "digital_asset"
    case game, equipment, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .property: return "Propiedad"
        case .house: return "Casa"
        case .vehicle: return "Vehículo"
        case .security: return "Título financiero"
        case .bankAccount: return "Cuenta bancaria"
        case .cashPool: return "Fondo común"
        case .contract: return "Contrato"
        case .document: return "Documento"
        case .reservation: return "Reservación"
        case .tripBooking: return "Reserva de viaje"
        case .trustAsset: return "Activo de trust"
        case .digitalAsset: return "Activo digital"
        case .game: return "Juego"
        case .equipment: return "Equipo"
        case .other: return "Otro"
        }
    }

    public var symbolName: String {
        switch self {
        case .property, .house: return "house.fill"
        case .vehicle: return "car.fill"
        case .security: return "chart.line.uptrend.xyaxis"
        case .bankAccount: return "banknote"
        case .cashPool: return "dollarsign.circle.fill"
        case .contract, .document: return "doc.text.fill"
        case .reservation: return "calendar.badge.clock"
        case .tripBooking: return "airplane"
        case .trustAsset: return "building.columns.fill"
        case .digitalAsset: return "externaldrive.fill.badge.icloud"
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
    /// F.RESOURCE.4 — ubicación opcional. A diferencia de eventos, no es
    /// obligatoria (recursos no físicos como cuentas bancarias o juegos
    /// digitales no la necesitan).
    public let locationText: String?
    /// 2026-06-09 — metadata jsonb type-specific (vin/make/model para
    /// vehicles, account_number/expiration para bank_accounts, etc.). El
    /// backend ya tiene resources.metadata jsonb NOT NULL desde el inicio;
    /// iOS no la decodificaba. Defaults a `.object([:])` si no viene.
    public let metadata: JSONValue

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
        case locationText = "location_text"
        case metadata
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
        createdAt: Date? = nil,
        locationText: String? = nil,
        metadata: JSONValue = .object([:])
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
        self.locationText = locationText
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.resourceType = try c.decode(String.self, forKey: .resourceType)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.estimatedValue = try c.decodeIfPresent(Double.self, forKey: .estimatedValue)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.canonicalOwnerActorId = try c.decodeIfPresent(UUID.self, forKey: .canonicalOwnerActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        // F.RESOURCE.4 — back-compat: shapes viejos no traen el campo.
        self.locationText = try c.decodeIfPresent(String.self, forKey: .locationText)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
    }

    public var type: ResourceType { ResourceType(rawValue: resourceType) ?? .other }

    /// Helper para leer un string del metadata jsonb (e.g. "vin", "make").
    public func metadataString(_ key: String) -> String? {
        guard case .object(let obj) = metadata,
              case .string(let s)? = obj[key],
              !s.isEmpty else { return nil }
        return s
    }
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
    /// R.2M-3: comportamientos que el TIPO soporta (reservable, monetary, …).
    public let capabilities: [String]
    /// R.2M-3: acciones que ESTE actor puede ejecutar ahora (capability ∩ rights).
    /// El frontend renderiza la UX desde aquí, nunca desde `resource_type`.
    public let availableActions: [AvailableAction]
    /// R.2M-3: por qué este actor ve el recurso (p. ej. ["USE", "GOVERN via Familia"]).
    public let whyVisible: [String]

    enum CodingKeys: String, CodingKey {
        case resource
        case rights
        case capabilities
        case availableActions = "available_actions"
        case whyVisible = "why_visible"
    }

    public init(
        resource: Resource,
        rights: [ResourceRight] = [],
        capabilities: [String] = [],
        availableActions: [AvailableAction] = [],
        whyVisible: [String] = []
    ) {
        self.resource = resource
        self.rights = rights
        self.capabilities = capabilities
        self.availableActions = availableActions
        self.whyVisible = whyVisible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resource = try c.decode(Resource.self, forKey: .resource)
        self.rights = try c.decodeIfPresent([ResourceRight].self, forKey: .rights) ?? []
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
        self.whyVisible = try c.decodeIfPresent([String].self, forKey: .whyVisible) ?? []
    }

    /// Razones por las que un actor ve este recurso ("Por qué aparece aquí").
    public func reasons(for actorId: UUID) -> [ResourceRight] {
        rights.filter { $0.holderActorId == actorId }
    }

    /// ¿El backend ofrece esta acción habilitada para este actor?
    public func can(_ actionKey: String) -> Bool {
        availableActions.can(actionKey)
    }

    /// Acciones de una sección de UI (reservations, money, beneficiaries, …).
    public func actions(in section: ResourceActionSection) -> [AvailableAction] {
        availableActions.inSection(section.rawValue)
    }
}

/// Secciones de UI que agrupan las available_actions. El orden define el render.
public enum ResourceActionSection: String, CaseIterable, Sendable {
    case reservations, money, beneficiaries, ownership, documents, approvals, maintenance, audit, rights

    public var title: String {
        switch self {
        case .reservations: return "Reservaciones"
        case .money: return "Dinero"
        case .beneficiaries: return "Beneficiarios"
        case .ownership: return "Participaciones"
        case .documents: return "Documentos"
        case .approvals: return "Aprobaciones"
        case .maintenance: return "Mantenimiento"
        case .audit: return "Auditoría"
        case .rights: return "Derechos"
        }
    }

    public var symbolName: String {
        switch self {
        case .reservations: return "calendar.badge.clock"
        case .money: return "banknote"
        case .beneficiaries: return "gift.fill"
        case .ownership: return "chart.pie.fill"
        case .documents: return "doc.text.fill"
        case .approvals: return "checkmark.seal.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .audit: return "doc.text.magnifyingglass"
        case .rights: return "key.fill"
        }
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
