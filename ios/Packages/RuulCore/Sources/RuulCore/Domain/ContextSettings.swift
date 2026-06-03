import Foundation

/// F.1A-2 — Configuración del contexto.
/// Mirror del jsonb que devuelve `context_settings_summary(context_id)`.
public struct ContextSettings: Decodable, Sendable, Equatable {
    public let contextActorId: UUID
    public let general: ContextGeneralSummary
    public let decisionsConfig: ContextDecisionsConfig
    public let moneyConfig: ContextMoneyConfig
    public let reservationsConfig: ContextReservationsConfig
    public let invitationsConfig: ContextInvitationsConfig
    public let availableActions: [String]

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case general
        case decisionsConfig = "decisions_config"
        case moneyConfig = "money_config"
        case reservationsConfig = "reservations_config"
        case invitationsConfig = "invitations_config"
        case availableActions = "available_actions"
    }

    public init(
        contextActorId: UUID,
        general: ContextGeneralSummary,
        decisionsConfig: ContextDecisionsConfig,
        moneyConfig: ContextMoneyConfig,
        reservationsConfig: ContextReservationsConfig,
        invitationsConfig: ContextInvitationsConfig,
        availableActions: [String]
    ) {
        self.contextActorId = contextActorId
        self.general = general
        self.decisionsConfig = decisionsConfig
        self.moneyConfig = moneyConfig
        self.reservationsConfig = reservationsConfig
        self.invitationsConfig = invitationsConfig
        self.availableActions = availableActions
    }

    public func can(_ action: String) -> Bool { availableActions.contains(action) }
}

public struct ContextGeneralSummary: Decodable, Sendable, Equatable {
    public let displayName: String
    public let description: String?
    public let subtype: String?
    public let visibility: String?
    public let memberCount: Int
    public let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case description
        case subtype
        case visibility
        case memberCount = "member_count"
        case imageUrl = "image_url"
    }
}

public struct ContextDecisionsConfig: Decodable, Sendable, Equatable {
    public let defaultVotingModel: String
    public let quorum: String
    public let majorityRule: String

    enum CodingKeys: String, CodingKey {
        case defaultVotingModel = "default_voting_model"
        case quorum
        case majorityRule = "majority_rule"
    }
}

public struct ContextMoneyConfig: Decodable, Sendable, Equatable {
    public let currency: String
    public let defaultSplit: String
    public let settlementPolicy: String

    enum CodingKeys: String, CodingKey {
        case currency
        case defaultSplit = "default_split"
        case settlementPolicy = "settlement_policy"
    }
}

public struct ContextReservationsConfig: Decodable, Sendable, Equatable {
    public let priorityPolicy: String
    public let conflictResolution: String
    public let cancellationPolicy: String

    enum CodingKeys: String, CodingKey {
        case priorityPolicy = "priority_policy"
        case conflictResolution = "conflict_resolution"
        case cancellationPolicy = "cancellation_policy"
    }
}

public struct ContextInvitationsConfig: Decodable, Sendable, Equatable {
    public let whoCanInvite: String
    public let openInvites: Bool

    enum CodingKeys: String, CodingKey {
        case whoCanInvite = "who_can_invite"
        case openInvites = "open_invites"
    }
}
