import Foundation

/// V3 Resources Deep — Fase B.1. Decodes the `subtype` jsonb returned
/// by `group_resource_detail(...)` when `resource_type='asset'`.
/// Mirrors `public.group_resource_assets` 1:1 (the SQL wraps the row
/// via `to_jsonb(a)`).
public struct AssetSubtypeData: Decodable, Sendable, Hashable {
    public let resourceId: UUID
    public let assetKind: String?
    public let serialNumber: String?
    public let currentValue: Decimal?
    public let currentValueUnit: String?
    public let condition: AssetCondition?
    public let custodianMembershipId: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceId            = "resource_id"
        case assetKind             = "asset_kind"
        case serialNumber          = "serial_number"
        case currentValue          = "current_value"
        case currentValueUnit      = "current_value_unit"
        case condition
        case custodianMembershipId = "custodian_membership_id"
        case createdAt             = "created_at"
        case updatedAt             = "updated_at"
    }

    public init(
        resourceId: UUID,
        assetKind: String? = nil,
        serialNumber: String? = nil,
        currentValue: Decimal? = nil,
        currentValueUnit: String? = nil,
        condition: AssetCondition? = nil,
        custodianMembershipId: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.assetKind = assetKind
        self.serialNumber = serialNumber
        self.currentValue = currentValue
        self.currentValueUnit = currentValueUnit
        self.condition = condition
        self.custodianMembershipId = custodianMembershipId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId            = try c.decode(UUID.self, forKey: .resourceId)
        self.assetKind             = try c.decodeIfPresent(String.self, forKey: .assetKind)
        self.serialNumber          = try c.decodeIfPresent(String.self, forKey: .serialNumber)
        self.currentValue          = try c.decodeIfPresent(Decimal.self, forKey: .currentValue)
        self.currentValueUnit      = try c.decodeIfPresent(String.self, forKey: .currentValueUnit)
        if let raw = try c.decodeIfPresent(String.self, forKey: .condition) {
            self.condition = AssetCondition(rawValue: raw)
        } else {
            self.condition = nil
        }
        self.custodianMembershipId = try c.decodeIfPresent(UUID.self, forKey: .custodianMembershipId)
        self.createdAt             = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt             = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// Canonical asset condition whitelist (matches BD CHECK
/// `group_resource_assets_condition_check`). `mark_asset_condition`
/// dispatches the right `resource.*` event based on transitions.
public enum AssetCondition: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case good
    case used
    case damaged
    case repaired
    case retired

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .good:     return L10n.Resources.conditionGood
        case .used:     return L10n.Resources.conditionUsed
        case .damaged:  return L10n.Resources.conditionDamaged
        case .repaired: return L10n.Resources.conditionRepaired
        case .retired:  return L10n.Resources.conditionRetired
        }
    }

    public var systemImageName: String {
        switch self {
        case .good:     return "checkmark.circle"
        case .used:     return "circle"
        case .damaged:  return "exclamationmark.triangle"
        case .repaired: return "wrench.adjustable"
        case .retired:  return "archivebox"
        }
    }
}
