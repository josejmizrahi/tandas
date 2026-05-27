import Foundation

/// Foundation Acceptance — per-primitive readiness derived by
/// `public.group_foundation_status(p_group_id)`. Five primitives
/// (Members / Boundary / Purpose / Rules / Resources) + an overall
/// `.ready` / `.notReady` summary. Decoded straight from the nested
/// jsonb the RPC returns.
public enum FoundationPrimitiveStatus: String, Codable, Sendable, Hashable {
    case complete
    case incomplete

    public var isComplete: Bool { self == .complete }
}

public enum FoundationOverallStatus: String, Codable, Sendable, Hashable {
    case ready
    case notReady = "not_ready"

    public var isReady: Bool { self == .ready }
}

public enum FoundationPrimitiveKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case members
    case boundary
    case purpose
    case rules
    case resources

    public var id: String { rawValue }

    /// Canonical render order in the readiness card.
    public static let displayOrder: [FoundationPrimitiveKind] = [
        .members, .boundary, .purpose, .rules, .resources
    ]

    public var systemImageName: String {
        switch self {
        case .members:   return "person.3"
        case .boundary:  return "shield"
        case .purpose:   return "flag"
        case .rules:     return "list.bullet.rectangle"
        case .resources: return "square.stack.3d.up"
        }
    }
}

/// Per-primitive completeness row. Optional fields capture the
/// jsonb shapes the backend may emit (e.g. boundary carries both
/// `active_count` and `pending_invites_count`).
public struct GroupFoundationPrimitive: Codable, Equatable, Sendable, Hashable {
    public let status: FoundationPrimitiveStatus
    public let activeCount: Int?
    public let pendingInvitesCount: Int?
    public let required: String?

    enum CodingKeys: String, CodingKey {
        case status
        case activeCount         = "active_count"
        case pendingInvitesCount = "pending_invites_count"
        case required
    }

    public init(
        status: FoundationPrimitiveStatus,
        activeCount: Int? = nil,
        pendingInvitesCount: Int? = nil,
        required: String? = nil
    ) {
        self.status = status
        self.activeCount = activeCount
        self.pendingInvitesCount = pendingInvitesCount
        self.required = required
    }

    /// Tolerant decode: unknown `status` falls back to `.incomplete`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawStatus = try c.decode(String.self, forKey: .status)
        self.status = FoundationPrimitiveStatus(rawValue: rawStatus) ?? .incomplete
        self.activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount)
        self.pendingInvitesCount = try c.decodeIfPresent(Int.self, forKey: .pendingInvitesCount)
        self.required = try c.decodeIfPresent(String.self, forKey: .required)
    }

    public var isComplete: Bool { status.isComplete }
}

public struct GroupFoundationStatus: Codable, Equatable, Sendable, Hashable {
    public let groupId: UUID
    public let members: GroupFoundationPrimitive
    public let boundary: GroupFoundationPrimitive
    public let purpose: GroupFoundationPrimitive
    public let rules: GroupFoundationPrimitive
    public let resources: GroupFoundationPrimitive
    public let overallStatus: FoundationOverallStatus

    enum CodingKeys: String, CodingKey {
        case groupId       = "group_id"
        case members
        case boundary
        case purpose
        case rules
        case resources
        case overallStatus = "overall_status"
    }

    public init(
        groupId: UUID,
        members: GroupFoundationPrimitive,
        boundary: GroupFoundationPrimitive,
        purpose: GroupFoundationPrimitive,
        rules: GroupFoundationPrimitive,
        resources: GroupFoundationPrimitive,
        overallStatus: FoundationOverallStatus
    ) {
        self.groupId = groupId
        self.members = members
        self.boundary = boundary
        self.purpose = purpose
        self.rules = rules
        self.resources = resources
        self.overallStatus = overallStatus
    }

    /// Tolerant decode for `overall_status` (defaults to `.notReady`
    /// on unknown values so a forward-compatible backend never
    /// crashes the client).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.members = try c.decode(GroupFoundationPrimitive.self, forKey: .members)
        self.boundary = try c.decode(GroupFoundationPrimitive.self, forKey: .boundary)
        self.purpose = try c.decode(GroupFoundationPrimitive.self, forKey: .purpose)
        self.rules = try c.decode(GroupFoundationPrimitive.self, forKey: .rules)
        self.resources = try c.decode(GroupFoundationPrimitive.self, forKey: .resources)
        let raw = try c.decode(String.self, forKey: .overallStatus)
        self.overallStatus = FoundationOverallStatus(rawValue: raw) ?? .notReady
    }
}

public extension GroupFoundationStatus {
    var isReady: Bool { overallStatus.isReady }

    /// Lookup helper used by the View to render rows by kind.
    func primitive(for kind: FoundationPrimitiveKind) -> GroupFoundationPrimitive {
        switch kind {
        case .members:   return members
        case .boundary:  return boundary
        case .purpose:   return purpose
        case .rules:     return rules
        case .resources: return resources
        }
    }

    /// Primitives still missing — drives the "Needs setup" hints.
    var incompletePrimitives: [FoundationPrimitiveKind] {
        FoundationPrimitiveKind.displayOrder.filter { !primitive(for: $0).isComplete }
    }

    /// 0…1 ratio of complete primitives. Useful as a progress hint.
    var completionRatio: Double {
        let total = Double(FoundationPrimitiveKind.allCases.count)
        let done = Double(FoundationPrimitiveKind.allCases.filter { primitive(for: $0).isComplete }.count)
        return total == 0 ? 0 : done / total
    }
}
