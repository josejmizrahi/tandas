import Foundation

struct Group: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let groupType: GroupType
    let inviteCode: String
    let coverImageName: String?
    let eventVocabulary: String                // maps to groups.event_label
    let frequencyType: FrequencyType?
    let frequencyConfig: FrequencyConfig?
    let finesEnabled: Bool
    let rotationMode: RotationMode
    let createdBy: UUID
    let createdAt: Date

    // MARK: - Platform V2 fields (migration 00019)

    /// Template id this group was created from. Default: `recurring_dinner`.
    let baseTemplate: String?
    /// Module ids active in this group. Composes which Resources/Rules/
    /// SystemEventTypes are valid here.
    let activeModules: [String]?
    /// Per-group governance configuration. Drives `GovernanceService`
    /// permission checks. Defaults backfilled to `recurring_dinner` template.
    let governance: GovernanceRules?
    /// Consolidated template-specific settings. New code reads from this
    /// jsonb; legacy flat fields (eventVocabulary, frequencyType, etc.)
    /// remain populated during the 2-week paridad window.
    let settings: GroupSettings?

    enum CodingKeys: String, CodingKey {
        case id, name, description, governance, settings
        case groupType        = "group_type"
        case inviteCode       = "invite_code"
        case coverImageName   = "cover_image_name"
        case eventVocabulary  = "event_label"
        case frequencyType    = "frequency_type"
        case frequencyConfig  = "frequency_config"
        case finesEnabled     = "fines_enabled"
        case rotationMode     = "rotation_mode"
        case baseTemplate     = "base_template"
        case activeModules    = "active_modules"
        case createdBy        = "created_by"
        case createdAt        = "created_at"
    }

    init(
        id: UUID,
        name: String,
        description: String? = nil,
        groupType: GroupType = .recurringDinner,
        inviteCode: String,
        coverImageName: String? = nil,
        eventVocabulary: String = "evento",
        frequencyType: FrequencyType? = nil,
        frequencyConfig: FrequencyConfig? = nil,
        finesEnabled: Bool = true,
        rotationMode: RotationMode = .manual,
        baseTemplate: String? = "recurring_dinner",
        activeModules: [String]? = nil,
        governance: GovernanceRules? = nil,
        settings: GroupSettings? = nil,
        createdBy: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.groupType = groupType
        self.inviteCode = inviteCode
        self.coverImageName = coverImageName
        self.eventVocabulary = eventVocabulary
        self.frequencyType = frequencyType
        self.frequencyConfig = frequencyConfig
        self.finesEnabled = finesEnabled
        self.rotationMode = rotationMode
        self.baseTemplate = baseTemplate
        self.activeModules = activeModules
        self.governance = governance
        self.settings = settings
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    /// Tolerant decoder: missing new columns (e.g. on a not-yet-migrated DB)
    /// fall back to defaults. This keeps Phase 1 fixtures and tests working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.name            = try c.decode(String.self, forKey: .name)
        self.description     = try c.decodeIfPresent(String.self, forKey: .description)
        self.groupType       = (try? c.decode(GroupType.self, forKey: .groupType)) ?? .recurringDinner
        self.inviteCode      = try c.decode(String.self, forKey: .inviteCode)
        self.coverImageName  = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.eventVocabulary = (try? c.decode(String.self, forKey: .eventVocabulary)) ?? "evento"
        self.frequencyType   = try c.decodeIfPresent(FrequencyType.self, forKey: .frequencyType)
        self.frequencyConfig = try c.decodeIfPresent(FrequencyConfig.self, forKey: .frequencyConfig)
        self.finesEnabled    = (try? c.decode(Bool.self, forKey: .finesEnabled)) ?? true
        self.rotationMode    = (try? c.decode(RotationMode.self, forKey: .rotationMode)) ?? .manual
        self.baseTemplate    = try c.decodeIfPresent(String.self, forKey: .baseTemplate)
        self.activeModules   = try c.decodeIfPresent([String].self, forKey: .activeModules)
        self.governance      = try c.decodeIfPresent(GovernanceRules.self, forKey: .governance)
        self.settings        = try c.decodeIfPresent(GroupSettings.self,  forKey: .settings)
        self.createdBy       = try c.decode(UUID.self, forKey: .createdBy)
        self.createdAt       = try c.decode(Date.self, forKey: .createdAt)
    }

    // MARK: - Convenience

    /// Returns the effective governance for this group: either the rules
    /// stored on this row, or template defaults if none are configured.
    public var effectiveGovernance: GovernanceRules {
        governance ?? .recurringDinnerDefaults
    }

    /// Returns the effective base template id, defaulting to recurring_dinner
    /// for legacy rows that haven't been backfilled.
    public var effectiveBaseTemplate: String {
        baseTemplate ?? "recurring_dinner"
    }

    /// Returns active module ids, falling back to the V1 default set if
    /// none are configured (legacy rows pre-migration 00019).
    public var effectiveActiveModules: [String] {
        activeModules ?? ["basic_fines", "rotating_host", "rsvp", "check_in", "appeal_voting"]
    }
}

struct GroupDetail: Codable, Sendable {
    let group: Group
    let memberCount: Int
    let myRole: String  // "admin" | "member"
}

struct CreateGroupParams: Sendable {
    let name: String
    let description: String?
    let eventLabel: String
    let currency: String
    let groupType: GroupType
    let coverImageName: String?
    let defaultDayOfWeek: Int?
    let defaultStartTime: String?
    let defaultLocation: String?
}
