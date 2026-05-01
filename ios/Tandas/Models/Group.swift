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

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case groupType        = "group_type"
        case inviteCode       = "invite_code"
        case coverImageName   = "cover_image_name"
        case eventVocabulary  = "event_label"
        case frequencyType    = "frequency_type"
        case frequencyConfig  = "frequency_config"
        case finesEnabled     = "fines_enabled"
        case rotationMode     = "rotation_mode"
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
        self.createdBy       = try c.decode(UUID.self, forKey: .createdBy)
        self.createdAt       = try c.decode(Date.self, forKey: .createdAt)
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
