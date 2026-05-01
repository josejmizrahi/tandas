import Foundation

/// In-memory mutable draft of a group during the founder onboarding flow.
/// Persisted (via JSON encoding) inside `OnboardingProgress.draftJSON` so the
/// flow can resume exactly where the user left off.
struct GroupDraft: Codable, Sendable, Hashable {
    var name: String
    var coverImageName: String?
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
}
