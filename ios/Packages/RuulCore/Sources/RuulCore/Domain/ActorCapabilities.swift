import Foundation

/// R.2S.1 — Capabilities universales del actor. El frontend NO decide
/// comportamiento por `actor_subtype`: consume capabilities y catálogo.
/// Mirror del jsonb que devuelve `actor_capabilities(p_actor_id)`.
public struct ActorCapabilities: Decodable, Sendable, Equatable, Hashable {
    public let actorId: UUID
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.actorKind = try c.decode(ActorKind.self, forKey: .actorKind)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    public init(
        actorId: UUID,
        actorKind: ActorKind,
        actorSubtype: String,
        capabilities: [String]
    ) {
        self.actorId = actorId
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.capabilities = capabilities
    }

    public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
    public func has(_ capability: ActorCapabilityKey) -> Bool { has(capability.rawValue) }
}

/// Mirror del jsonb que devuelve `actor_capabilities_catalog()`.
/// Contiene la lista global de capabilities + matriz subtype→capabilities.
public struct ActorCapabilitiesCatalog: Decodable, Sendable, Equatable {
    public let capabilities: [ActorCapabilityCatalogEntry]
    public let subtypes: [ActorSubtypeCapabilities]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.capabilities = try c.decodeIfPresent([ActorCapabilityCatalogEntry].self, forKey: .capabilities) ?? []
        self.subtypes = try c.decodeIfPresent([ActorSubtypeCapabilities].self, forKey: .subtypes) ?? []
    }

    public init(
        capabilities: [ActorCapabilityCatalogEntry],
        subtypes: [ActorSubtypeCapabilities]
    ) {
        self.capabilities = capabilities
        self.subtypes = subtypes
    }

    enum CodingKeys: String, CodingKey {
        case capabilities
        case subtypes
    }

    /// Capabilities que un subtype tiene en el catálogo (vacío si el subtype no existe).
    public func capabilities(forSubtype subtype: String) -> [String] {
        subtypes.first { $0.actorSubtype == subtype }?.capabilities ?? []
    }

    /// Subtypes que poseen una capability — útil para filtrar pickers.
    public func subtypes(with capability: ActorCapabilityKey) -> [String] {
        subtypes.filter { $0.capabilities.contains(capability.rawValue) }.map(\.actorSubtype)
    }

    /// Display name de una capability — para chips/etiquetas en UI.
    public func displayName(for capabilityKey: String) -> String? {
        capabilities.first { $0.capabilityKey == capabilityKey }?.displayName
    }
}

public struct ActorCapabilityCatalogEntry: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let capabilityKey: String
    public let displayName: String
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case capabilityKey = "capability_key"
        case displayName = "display_name"
        case description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.capabilityKey = try c.decode(String.self, forKey: .capabilityKey)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public init(capabilityKey: String, displayName: String, description: String? = nil) {
        self.capabilityKey = capabilityKey
        self.displayName = displayName
        self.description = description
    }

    public var id: String { capabilityKey }
}

public struct ActorSubtypeCapabilities: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let actorSubtype: String
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case actorSubtype = "actor_subtype"
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    public init(actorSubtype: String, capabilities: [String]) {
        self.actorSubtype = actorSubtype
        self.capabilities = capabilities
    }

    public var id: String { actorSubtype }
}

/// Espejo del catálogo `actor_capabilities_catalog` (12 keys). Permite gateado
/// type-safe sin perder string interop con el backend.
public enum ActorCapabilityKey: String, Sendable, Hashable, CaseIterable {
    case canHaveMembers = "can_have_members"
    case canHoldAssets = "can_hold_assets"
    case canHoldMoney = "can_hold_money"
    case canIssueDecisions = "can_issue_decisions"
    case canReceiveContributions = "can_receive_contributions"
    case canHaveBeneficiaries = "can_have_beneficiaries"
    case canHaveShareholders = "can_have_shareholders"
    case canHaveTrustees = "can_have_trustees"
    case canReceiveObligations = "can_receive_obligations"
    case canIssueObligations = "can_issue_obligations"
    case canGovernResources = "can_govern_resources"
    case canOwnResources = "can_own_resources"
}
