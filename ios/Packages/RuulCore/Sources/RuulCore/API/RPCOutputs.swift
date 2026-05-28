import Foundation

/// Wire-format DTOs for RPC and table responses. Stay as close to the
/// Postgres rows as possible; the surrounding repositories convert these
/// into `Domain/` models before handing off to features.

// MARK: - accept_invite returns TABLE(group_id, membership_id)

struct AcceptInviteRow: Decodable {
    let groupId: UUID
    let membershipId: UUID

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case membershipId = "membership_id"
    }
}

// MARK: - record_settlement returns TABLE(settlement_id, transaction_id)

struct RecordSettlementRow: Decodable {
    let settlementId: UUID
    let transactionId: UUID

    enum CodingKeys: String, CodingKey {
        case settlementId = "settlement_id"
        case transactionId = "transaction_id"
    }
}

// MARK: - group_summary returns jsonb

struct GroupSummaryDTO: Decodable {
    let groupId: UUID
    let memberCount: Int
    let openDecisions: Int
    let openDisputes: Int
    let openObligations: Int
    let recentEvents: [RecentEvent]

    struct RecentEvent: Decodable {
        let id: Int64
        let eventType: String
        let summary: String?
        let occurredAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case eventType = "event_type"
            case summary
            case occurredAt = "occurred_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case memberCount = "member_count"
        case openDecisions = "open_decisions"
        case openDisputes = "open_disputes"
        case openObligations = "open_obligations"
        case recentEvents = "recent_events"
    }
}

extension GroupSummaryDTO {
    func toDomain() -> CanonicalGroupSummary {
        CanonicalGroupSummary(
            groupId: groupId,
            memberCount: memberCount,
            openDecisions: openDecisions,
            openDisputes: openDisputes,
            openObligations: openObligations,
            recentEvents: recentEvents.map {
                CanonicalGroupSummary.Event(
                    id: $0.id,
                    eventType: $0.eventType,
                    summary: $0.summary,
                    occurredAt: $0.occurredAt
                )
            }
        )
    }
}

// MARK: - member_obligation_summary returns TABLE(obligation_id, kind, amount_outstanding, owed_to_kind, owed_to_membership_id, owed_to_label)

struct MemberObligationRow: Decodable {
    let obligationId: UUID
    let kind: String
    let amountOutstanding: Decimal
    let owedToKind: String
    let owedToMembershipId: UUID?
    let owedToLabel: String

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case kind
        case amountOutstanding = "amount_outstanding"
        case owedToKind = "owed_to_kind"
        case owedToMembershipId = "owed_to_membership_id"
        case owedToLabel = "owed_to_label"
    }
}

extension MemberObligationRow {
    func toDomain() -> ObligationSummary {
        ObligationSummary(
            id: obligationId,
            kind: kind,
            amountOutstanding: amountOutstanding,
            owedToKind: owedToKind,
            owedToMembershipId: owedToMembershipId,
            owedToLabel: owedToLabel
        )
    }
}

// MARK: - (legacy GroupRow/MembershipRow DTOs removed — listMyGroups
// now uses the canonical `list_my_groups()` RPC which returns the
// pre-flattened ListMyGroupsRow shape; no embedded join is needed.)

// MARK: - list_my_groups()

/// Wire row from `public.list_my_groups()`. One row per group the
/// caller is an active member of, with the joined membership id
/// flattened so iOS never sees `group_memberships` directly.
struct ListMyGroupsRow: Decodable {
    let membershipId: UUID
    let groupId: UUID
    let name: String
    let slug: String?
    let category: String?
    let purposeSummary: String?
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case membershipId   = "membership_id"
        case groupId        = "group_id"
        case name
        case slug
        case category
        case purposeSummary = "purpose_summary"
        case joinedAt       = "joined_at"
    }
}

extension ListMyGroupsRow {
    func toDomain() -> GroupListItem {
        GroupListItem(
            id: groupId,
            name: name,
            slug: slug,
            category: category,
            purposeSummary: purposeSummary,
            membershipId: membershipId
        )
    }
}

// MARK: - group_dissolution_active(p_group_id)

/// Wire envelope returned by `group_dissolution_active(p_group_id)`.
/// Backend emits `{}` jsonb when no active dissolution exists, so
/// every field is optional and `toDomain()` returns `nil` until at
/// least `dissolution_id` is present.
struct GroupDissolutionWireDTO: Decodable {
    let dissolutionId: UUID?
    let groupId: UUID?
    let initiatedBy: UUID?
    let initiatedByDisplayName: String?
    let sourceDecisionId: UUID?
    let status: String?
    let reason: String?
    let proposedAt: Date?
    let approvedAt: Date?
    let executedAt: Date?
    let updatedAt: Date?
    let openObligationsCount: Int?

    enum CodingKeys: String, CodingKey {
        case dissolutionId          = "dissolution_id"
        case groupId                = "group_id"
        case initiatedBy            = "initiated_by"
        case initiatedByDisplayName = "initiated_by_display_name"
        case sourceDecisionId       = "source_decision_id"
        case status
        case reason
        case proposedAt             = "proposed_at"
        case approvedAt             = "approved_at"
        case executedAt             = "executed_at"
        case updatedAt              = "updated_at"
        case openObligationsCount   = "open_obligations_count"
    }

    func toDomain() -> GroupDissolution? {
        guard let dissolutionId, let groupId else { return nil }
        let parsedStatus = status.flatMap { DissolutionStatus(rawValue: $0) } ?? .proposed
        return GroupDissolution(
            id: dissolutionId,
            groupId: groupId,
            initiatedBy: initiatedBy,
            initiatedByDisplayName: initiatedByDisplayName,
            sourceDecisionId: sourceDecisionId,
            status: parsedStatus,
            reason: reason,
            proposedAt: proposedAt,
            approvedAt: approvedAt,
            executedAt: executedAt,
            updatedAt: updatedAt,
            openObligationsCount: openObligationsCount ?? 0
        )
    }
}

// MARK: - group_members(p_group_id)

/// Wire row from `public.group_members(p_group_id) returns table(...)`.
/// Kept as a plain DTO so the wire-level concerns (string avatar_url
/// that may not parse as URL, numeric/text status) stay isolated from
/// the domain `MemberListItem`.
struct GroupMemberRow: Decodable {
    let membershipId: UUID
    let userId: UUID?
    let displayName: String
    let username: String?
    let avatarUrl: String?
    let status: String
    let membershipType: String
    let roleNames: [String]
    let joinedAt: Date?
    let isCurrentUser: Bool

    enum CodingKeys: String, CodingKey {
        case membershipId   = "membership_id"
        case userId         = "user_id"
        case displayName    = "display_name"
        case username
        case avatarUrl      = "avatar_url"
        case status
        case membershipType = "membership_type"
        case roleNames      = "role_names"
        case joinedAt       = "joined_at"
        case isCurrentUser  = "is_current_user"
    }
}

extension GroupMemberRow {
    /// Maps the wire row into the domain model the Members surface
    /// consumes. Unknown enum values fall back to safe defaults so a
    /// new status from the backend never crashes the UI.
    func toDomain() -> MemberListItem {
        let parsedStatus = MembershipStatus(rawValue: status) ?? .active
        let parsedType = MembershipType(rawValue: membershipType) ?? .member
        let parsedURL: URL? = {
            guard let raw = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return URL(string: raw)
        }()
        return MemberListItem(
            id: membershipId,
            userId: userId,
            displayName: displayName,
            avatarURL: parsedURL,
            status: parsedStatus,
            membershipType: parsedType,
            roleNames: roleNames,
            joinedAt: joinedAt,
            isCurrentUser: isCurrentUser
        )
    }
}
