import Foundation

/// In-memory mutable draft of a group during the founder onboarding flow.
/// Persisted (via JSON encoding) inside `OnboardingProgress.draftJSON` so the
/// flow can resume exactly where the user left off.
struct GroupDraft: Codable, Sendable, Hashable {
    var name: String
    var coverImageName: String?
    /// Platform template id picked at the TemplateSelector step. Stored as
    /// raw string so it round-trips through OnboardingProgress.draftJSON
    /// even if the enum changes shape later. Defaults to "recurring_dinner"
    /// (the only V1 template).
    var template: String
    var eventVocabulary: String          // maps to groups.event_label
    var customVocabulary: String?
    var frequencyType: FrequencyType?
    var frequencyConfig: FrequencyConfig
    var finesEnabled: Bool
    var rotationMode: RotationMode
    var rules: [RuleDraft]

    /// Empty draft used at the start of the flow.
    static let empty = GroupDraft(
        name: "",
        coverImageName: nil,
        template: "recurring_dinner",
        eventVocabulary: "evento",
        customVocabulary: nil,
        frequencyType: nil,
        frequencyConfig: .empty,
        finesEnabled: true,
        rotationMode: .manual,
        rules: RuleDraft.defaults
    )

    var isReadyToCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var resolvedVocabulary: String {
        if eventVocabulary == "otro", let custom = customVocabulary?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return custom
        }
        return eventVocabulary
    }

    // Tolerant decode so any draftJSON persisted before Sprint 1b (which
    // didn't have `template`) restores cleanly with the V1 default.
    enum CodingKeys: String, CodingKey {
        case name, coverImageName, template, eventVocabulary, customVocabulary,
             frequencyType, frequencyConfig, finesEnabled, rotationMode, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name             = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.coverImageName   = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.template         = try c.decodeIfPresent(String.self, forKey: .template) ?? "recurring_dinner"
        self.eventVocabulary  = try c.decodeIfPresent(String.self, forKey: .eventVocabulary) ?? "evento"
        self.customVocabulary = try c.decodeIfPresent(String.self, forKey: .customVocabulary)
        self.frequencyType    = try c.decodeIfPresent(FrequencyType.self, forKey: .frequencyType)
        self.frequencyConfig  = try c.decodeIfPresent(FrequencyConfig.self, forKey: .frequencyConfig) ?? .empty
        self.finesEnabled     = try c.decodeIfPresent(Bool.self, forKey: .finesEnabled) ?? true
        self.rotationMode     = try c.decodeIfPresent(RotationMode.self, forKey: .rotationMode) ?? .manual
        self.rules            = try c.decodeIfPresent([RuleDraft].self, forKey: .rules) ?? RuleDraft.defaults
    }

    init(
        name: String,
        coverImageName: String?,
        template: String,
        eventVocabulary: String,
        customVocabulary: String?,
        frequencyType: FrequencyType?,
        frequencyConfig: FrequencyConfig,
        finesEnabled: Bool,
        rotationMode: RotationMode,
        rules: [RuleDraft]
    ) {
        self.name = name
        self.coverImageName = coverImageName
        self.template = template
        self.eventVocabulary = eventVocabulary
        self.customVocabulary = customVocabulary
        self.frequencyType = frequencyType
        self.frequencyConfig = frequencyConfig
        self.finesEnabled = finesEnabled
        self.rotationMode = rotationMode
        self.rules = rules
    }
}
