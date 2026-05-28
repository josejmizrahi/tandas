import Foundation

/// Primitiva 25 (Disolución). State machine for closing a group:
///
/// proposed → approved → executed
///                    ↘ liquidating → executed
///                    ↘ cancelled
///
/// Backend lifecycle:
/// - `propose_dissolution(...)` requires `group.dissolve`, inserts a
///   `proposed` row and auto-creates a supermajority vote (14 days,
///   66.66% threshold, 50% quorum).
/// - `approve_dissolution(...)` flips status → approved + approved_at.
///   Backend triggers this automatically when the linked vote passes.
/// - `finalize_dissolution(...)` requires `group.dissolve` + all
///   group_obligations resolved. Flips status → executed, the
///   `groups.status` → `dissolved`, and every active membership →
///   `left` with reason `dissolution`.
public enum DissolutionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case proposed
    case approved
    case liquidating
    case executed
    case cancelled

    public var label: LocalizedStringResource {
        switch self {
        case .proposed:    return L10n.Dissolution.statusProposed
        case .approved:    return L10n.Dissolution.statusApproved
        case .liquidating: return L10n.Dissolution.statusLiquidating
        case .executed:    return L10n.Dissolution.statusExecuted
        case .cancelled:   return L10n.Dissolution.statusCancelled
        }
    }

    /// `true` while the dissolution is still in progress and the
    /// group should surface a danger banner.
    public var isActive: Bool {
        switch self {
        case .proposed, .approved, .liquidating: return true
        case .executed, .cancelled:               return false
        }
    }
}

public struct GroupDissolution: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let initiatedBy: UUID?
    public let initiatedByDisplayName: String?
    public let sourceDecisionId: UUID?
    public let status: DissolutionStatus
    public let reason: String?
    public let proposedAt: Date?
    public let approvedAt: Date?
    public let executedAt: Date?
    public let updatedAt: Date?
    /// Number of `group_obligations` still open or partially settled.
    /// `finalize_dissolution` raises when this is > 0, so iOS shows a
    /// "settle pending obligations first" hint.
    public let openObligationsCount: Int

    enum CodingKeys: String, CodingKey {
        case id                       = "dissolution_id"
        case groupId                  = "group_id"
        case initiatedBy              = "initiated_by"
        case initiatedByDisplayName   = "initiated_by_display_name"
        case sourceDecisionId         = "source_decision_id"
        case status
        case reason
        case proposedAt               = "proposed_at"
        case approvedAt               = "approved_at"
        case executedAt               = "executed_at"
        case updatedAt                = "updated_at"
        case openObligationsCount     = "open_obligations_count"
    }

    public init(
        id: UUID,
        groupId: UUID,
        initiatedBy: UUID? = nil,
        initiatedByDisplayName: String? = nil,
        sourceDecisionId: UUID? = nil,
        status: DissolutionStatus = .proposed,
        reason: String? = nil,
        proposedAt: Date? = nil,
        approvedAt: Date? = nil,
        executedAt: Date? = nil,
        updatedAt: Date? = nil,
        openObligationsCount: Int = 0
    ) {
        self.id = id
        self.groupId = groupId
        self.initiatedBy = initiatedBy
        self.initiatedByDisplayName = initiatedByDisplayName
        self.sourceDecisionId = sourceDecisionId
        self.status = status
        self.reason = reason
        self.proposedAt = proposedAt
        self.approvedAt = approvedAt
        self.executedAt = executedAt
        self.updatedAt = updatedAt
        self.openObligationsCount = openObligationsCount
    }

    /// Tolerant decode: unknown statuses fall back to `.proposed` and
    /// missing optionals default to nil/0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.initiatedBy = try c.decodeIfPresent(UUID.self, forKey: .initiatedBy)
        self.initiatedByDisplayName = try c.decodeIfPresent(String.self, forKey: .initiatedByDisplayName)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "proposed"
        self.status = DissolutionStatus(rawValue: rawStatus) ?? .proposed
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.proposedAt = try c.decodeIfPresent(Date.self, forKey: .proposedAt)
        self.approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        self.executedAt = try c.decodeIfPresent(Date.self, forKey: .executedAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.openObligationsCount = try c.decodeIfPresent(Int.self, forKey: .openObligationsCount) ?? 0
    }
}

public extension GroupDissolution {
    /// `true` once the linked vote has passed and only the
    /// finalize step remains.
    var canFinalize: Bool { status == .approved && openObligationsCount == 0 }
}
