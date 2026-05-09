import Foundation

/// Read-only view of a rule for display in `RulesView`. Decodes the platform
/// columns (name, is_active, consequences) and the legacy columns
/// (title, action.amount_mxn) so it works for both legacy and platform-shape
/// rows. The `amountMXN` resolver checks both shapes.
public struct GroupRule: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let slug: String?
    public let code: String?
    public let title: String
    public let description: String?
    public let enabled: Bool
    public let isActive: Bool
    public let action: ActionEnvelope?
    public let consequences: [ConsequenceEnvelope]

    public init(
        id: UUID,
        groupId: UUID,
        slug: String? = nil,
        code: String?,
        title: String,
        description: String?,
        enabled: Bool,
        isActive: Bool,
        action: ActionEnvelope?,
        consequences: [ConsequenceEnvelope]
    ) {
        self.id = id
        self.groupId = groupId
        self.slug = slug
        self.code = code
        self.title = title
        self.description = description
        self.enabled = enabled
        self.isActive = isActive
        self.action = action
        self.consequences = consequences
    }

    public struct ActionEnvelope: Codable, Sendable, Hashable {
        public let type: String?
        public let amount_mxn: Int?

        public init(type: String?, amount_mxn: Int?) {
            self.type = type
            self.amount_mxn = amount_mxn
        }
    }

    public struct ConsequenceEnvelope: Codable, Sendable, Hashable {
        public let type: String?
        public let config: Config?

        public init(type: String?, config: Config?) {
            self.type = type
            self.config = config
        }

        public struct Config: Codable, Sendable, Hashable {
            public let amount: Int?
            public let baseAmount: Int?
            public let stepAmount: Int?
            public let stepMinutes: Int?

            public init(amount: Int?, baseAmount: Int?, stepAmount: Int?, stepMinutes: Int?) {
                self.amount = amount
                self.baseAmount = baseAmount
                self.stepAmount = stepAmount
                self.stepMinutes = stepMinutes
            }
        }
    }

    /// Resolves the display amount (MXN). Tries platform consequences first,
    /// then legacy action.amount_mxn. Returns nil if the rule isn't a fine.
    public var amountMXN: Int? {
        if let cons = consequences.first(where: { $0.type == "fine" }) {
            if let flat = cons.config?.amount { return flat }
            if let base = cons.config?.baseAmount { return base }
        }
        return action?.amount_mxn
    }

    /// Platform-shape forwarder for views. `name` is the platform column
    /// (`rules.name`); the legacy `title` column persists until
    /// `RulesPlatformOnly.md` E.2 drops it. Decoders populate both today.
    public var name: String { title }

    /// True when the rule is both `enabled` and `is_active` — the engine
    /// only fires rules where both are true.
    public var isLive: Bool { enabled && isActive }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId      = "group_id"
        case slug
        case code, title, description, enabled
        case isActive     = "is_active"
        case action
        case consequences
    }
}
