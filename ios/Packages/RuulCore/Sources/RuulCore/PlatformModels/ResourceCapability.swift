import Foundation

/// Per-resource capability block configuration per OpenPlatform Taxonomy §2.
///
/// Represents the (resource × capability) pair: when a capability is
/// "enabled" on a resource, a row exists here with that capability's
/// config. Enables progressive opt-in — a resource starts bare,
/// capabilities get added explicitly later.
///
/// Schema source: mig 00078. Decodes from `public.resource_capabilities`.
public struct ResourceCapability: Codable, Sendable, Hashable {
    public let resourceId: UUID
    public let capabilityBlockId: String
    public let config: JSONConfig
    public let enabled: Bool
    public let enabledAt: Date
    public let enabledBy: UUID?

    public init(
        resourceId: UUID,
        capabilityBlockId: String,
        config: JSONConfig = .object([:]),
        enabled: Bool = true,
        enabledAt: Date = .now,
        enabledBy: UUID? = nil
    ) {
        self.resourceId = resourceId
        self.capabilityBlockId = capabilityBlockId
        self.config = config
        self.enabled = enabled
        self.enabledAt = enabledAt
        self.enabledBy = enabledBy
    }

    public enum CodingKeys: String, CodingKey {
        case config, enabled
        case resourceId        = "resource_id"
        case capabilityBlockId = "capability_block_id"
        case enabledAt         = "enabled_at"
        case enabledBy         = "enabled_by"
    }
}
