import Foundation

/// V3 D.24 P12A — payload of `resource_detail_summary(p_resource_id)` RPC.
/// Single round-trip hidratante para `ResourceDetailView`:
/// resource + subtype polimórfico + owners (group_resource_owners actives)
/// + capabilities + 3 counts agregados + recent_activity[10].
///
/// iOS adopt iniciado en P12B-2 (solo ResourceDetail). Convive con el
/// path legacy: `loadDetail` (`group_resource_detail`) + `loadActivity`
/// (`group_events_for_entity`) siguen funcionando si la summary falla.
public struct ResourceDetailSummary: Sendable, Equatable, Hashable {
    public let resource: GroupResource
    public let subtype: RPCJSONValue?
    public let owners: [ResourceOwnerItem]
    public let capabilities: [ResourceCapabilityItem]
    public let commentsCount: Int
    public let attachmentsCount: Int
    public let openObligationsCount: Int
    public let recentActivity: [RecentActivityItem]
}

extension ResourceDetailSummary: Decodable {
    enum CodingKeys: String, CodingKey {
        case resource
        case subtype
        case owners
        case capabilities
        case commentsCount         = "comments_count"
        case attachmentsCount      = "attachments_count"
        case openObligationsCount  = "open_obligations_count"
        case recentActivity        = "recent_activity"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resource = try c.decode(GroupResource.self, forKey: .resource)
        self.subtype = try c.decodeIfPresent(RPCJSONValue.self, forKey: .subtype)
        self.owners = try c.decodeIfPresent([ResourceOwnerItem].self, forKey: .owners) ?? []
        self.capabilities = try c.decodeIfPresent([ResourceCapabilityItem].self, forKey: .capabilities) ?? []
        self.commentsCount = try c.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        self.attachmentsCount = try c.decodeIfPresent(Int.self, forKey: .attachmentsCount) ?? 0
        self.openObligationsCount = try c.decodeIfPresent(Int.self, forKey: .openObligationsCount) ?? 0
        self.recentActivity = try c.decodeIfPresent([RecentActivityItem].self, forKey: .recentActivity) ?? []
    }
}

public extension ResourceDetailSummary {
    /// Subtype lazy decoders — mirror `GroupResourceDetail` so the view
    /// can switch indistintamente entre los dos paths.
    var assetSubtype: AssetSubtypeData? { decodedSubtype(expected: .asset) }
    var fundSubtype:  FundSubtypeData?  { decodedSubtype(expected: .fund) }
    var spaceSubtype: SpaceSubtypeData? { decodedSubtype(expected: .space) }
    var rightSubtype: RightSubtypeData? { decodedSubtype(expected: .right) }
    var slotSubtype:  SlotSubtypeData?  { decodedSubtype(expected: .slot) }

    private func decodedSubtype<T: Decodable>(expected type: GroupResourceType) -> T? {
        guard resource.resourceType == type,
              let raw = subtype,
              case .object = raw else { return nil }
        do {
            let data = try JSONEncoder.tandas.encode(raw)
            return try JSONDecoder.tandas.decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}

/// V3 D.24 P3A — active row de `group_resource_owners`. El RPC ya
/// resuelve `display_name` via coalesce(profile.display_name,
/// profile.username, external_party.display_name).
public struct ResourceOwnerItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let ownerKind: String
    public let membershipId: UUID?
    public let externalPartyId: UUID?
    public let ownershipPct: Decimal?
    public let ownershipRole: String?
    public let startsAt: Date?
    public let endsAt: Date?
    public let sourceDecisionId: UUID?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerKind         = "owner_kind"
        case membershipId      = "membership_id"
        case externalPartyId   = "external_party_id"
        case ownershipPct      = "ownership_pct"
        case ownershipRole     = "ownership_role"
        case startsAt          = "starts_at"
        case endsAt            = "ends_at"
        case sourceDecisionId  = "source_decision_id"
        case displayName       = "display_name"
    }
}

/// V3 D.14 capability row from `group_resource_capabilities`. The RPC
/// preserves `config` as raw jsonb to keep the iOS surface forward-
/// compatible with new capability shapes.
public struct ResourceCapabilityItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { capabilityKey }
    public let capabilityKey: String
    public let enabled: Bool
    public let config: RPCJSONValue?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case capabilityKey  = "capability_key"
        case enabled
        case config
        case updatedAt      = "updated_at"
    }
}
