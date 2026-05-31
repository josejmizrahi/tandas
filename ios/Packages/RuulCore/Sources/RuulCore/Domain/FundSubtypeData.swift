import Foundation

/// V3 Resources Deep — Fase B.2. Decodes the `subtype` jsonb returned
/// by `group_resource_detail(...)` when `resource_type='fund'`.
/// Mirrors `public.group_resource_funds` 1:1.
public struct FundSubtypeData: Decodable, Sendable, Hashable {
    public let resourceId: UUID
    public let fundKind: FundKind?
    public let currency: String?
    public let isSharedPool: Bool?
    public let isInKind: Bool?
    public let thresholdTarget: Decimal?
    public let lockedAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceId      = "resource_id"
        case fundKind        = "fund_kind"
        case currency
        case isSharedPool    = "is_shared_pool"
        case isInKind        = "is_in_kind"
        case thresholdTarget = "threshold_target"
        case lockedAt        = "locked_at"
        case createdAt       = "created_at"
        case updatedAt       = "updated_at"
    }

    public init(
        resourceId: UUID,
        fundKind: FundKind? = nil,
        currency: String? = nil,
        isSharedPool: Bool? = nil,
        isInKind: Bool? = nil,
        thresholdTarget: Decimal? = nil,
        lockedAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.fundKind = fundKind
        self.currency = currency
        self.isSharedPool = isSharedPool
        self.isInKind = isInKind
        self.thresholdTarget = thresholdTarget
        self.lockedAt = lockedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId       = try c.decode(UUID.self, forKey: .resourceId)
        if let raw = try c.decodeIfPresent(String.self, forKey: .fundKind) {
            self.fundKind = FundKind(rawValue: raw)
        } else {
            self.fundKind = nil
        }
        self.currency         = try c.decodeIfPresent(String.self, forKey: .currency)
        self.isSharedPool     = try c.decodeIfPresent(Bool.self, forKey: .isSharedPool)
        self.isInKind         = try c.decodeIfPresent(Bool.self, forKey: .isInKind)
        self.thresholdTarget  = try c.decodeIfPresent(Decimal.self, forKey: .thresholdTarget)
        self.lockedAt         = try c.decodeIfPresent(Date.self, forKey: .lockedAt)
        self.createdAt        = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt        = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public var isLocked: Bool { lockedAt != nil }
}

/// Fund kinds whitelist (matches BD CHECK
/// `group_resource_funds_fund_kind_check`).
public enum FundKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case pool
    case protected
    case sharedPool = "shared_pool"

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .pool:       return L10n.Resources.fundKindPool
        case .protected:  return L10n.Resources.fundKindProtected
        case .sharedPool: return L10n.Resources.fundKindSharedPool
        }
    }
}
