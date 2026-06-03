import Foundation

/// F.1A-3 — Configuración de un recurso.
/// Mirror del jsonb que devuelve `resource_settings_summary(resource_id)`.
/// Las secciones de `policies` son capability-gated en el frontend: solo se
/// renderiza la sub-sección si `capabilities` contiene la capability.
public struct ResourceSettings: Decodable, Sendable, Equatable {
    public let resourceId: UUID
    public let general: ResourceGeneralSummary
    public let capabilities: [String]
    public let rightsSummary: [String: Int]
    public let policies: ResourcePolicies
    public let availableActions: [String]

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case general
        case capabilities
        case rightsSummary = "rights_summary"
        case policies
        case availableActions = "available_actions"
    }

    public init(
        resourceId: UUID,
        general: ResourceGeneralSummary,
        capabilities: [String],
        rightsSummary: [String: Int],
        policies: ResourcePolicies,
        availableActions: [String]
    ) {
        self.resourceId = resourceId
        self.general = general
        self.capabilities = capabilities
        self.rightsSummary = rightsSummary
        self.policies = policies
        self.availableActions = availableActions
    }

    public func can(_ action: String) -> Bool { availableActions.contains(action) }
    public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}

public struct ResourceGeneralSummary: Decodable, Sendable, Equatable {
    public let resourceType: String
    public let displayName: String
    public let description: String?
    public let status: String?
    public let estimatedValue: Double?
    public let currency: String?
    public let archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceType = "resource_type"
        case displayName = "display_name"
        case description
        case status
        case estimatedValue = "estimated_value"
        case currency
        case archivedAt = "archived_at"
    }
}

public struct ResourcePolicies: Decodable, Sendable, Equatable {
    public let reservable: ReservablePolicy
    public let monetary: MonetaryPolicy
    public let beneficiary: BeneficiaryPolicy
    public let documentable: DocumentablePolicy
}

public struct ReservablePolicy: Decodable, Sendable, Equatable {
    public let maxWindowDays: Int
    public let cancellationPolicy: String
    public let priorityPolicy: String
    public let capacity: Int

    enum CodingKeys: String, CodingKey {
        case maxWindowDays = "max_window_days"
        case cancellationPolicy = "cancellation_policy"
        case priorityPolicy = "priority_policy"
        case capacity
    }
}

public struct MonetaryPolicy: Decodable, Sendable, Equatable {
    public let currency: String
    public let settlementPolicy: String

    enum CodingKeys: String, CodingKey {
        case currency
        case settlementPolicy = "settlement_policy"
    }
}

public struct BeneficiaryPolicy: Decodable, Sendable, Equatable {
    public let beneficiaries: [JSONValue]
    public let distribution: String
}

public struct DocumentablePolicy: Decodable, Sendable, Equatable {
    public let versioningEnabled: Bool
    public let approvalsRequired: Int

    enum CodingKeys: String, CodingKey {
        case versioningEnabled = "versioning_enabled"
        case approvalsRequired = "approvals_required"
    }
}
