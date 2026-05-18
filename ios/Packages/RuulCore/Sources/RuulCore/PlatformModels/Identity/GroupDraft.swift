import Foundation

/// In-memory mutable draft of a group during the founder onboarding flow.
/// Persisted (via JSON encoding) inside `OnboardingProgress.draftJSON` so the
/// flow can resume exactly where the user left off.
///
/// Post BigBang (mig 00078): the draft only carries identity + template
/// preset choice + initial vocabulary. Decisions about recurrence, fines,
/// rotation, and rules move to the ResourceWizard (Phase 2 — progressive
/// opt-in per resource).
public struct GroupDraft: Codable, Sendable, Hashable {
    public var name: String
    public var coverImageName: String?
    /// Optional preset template id. Empty string = "empezar de cero" path.
    public var template: String
    /// User-facing word for "event" — surfaces as `settings.eventVocabulary`.
    public var eventVocabulary: String
    public var customVocabulary: String?

    public static let empty = GroupDraft(
        name: "",
        coverImageName: nil,
        template: "",
        eventVocabulary: "evento",
        customVocabulary: nil
    )

    public var isReadyToCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var resolvedVocabulary: String {
        if eventVocabulary == "otro",
           let custom = customVocabulary?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return custom
        }
        return eventVocabulary
    }

    public enum CodingKeys: String, CodingKey {
        case name, coverImageName, template, eventVocabulary, customVocabulary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name             = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.coverImageName   = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.template         = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        self.eventVocabulary  = try c.decodeIfPresent(String.self, forKey: .eventVocabulary) ?? "evento"
        self.customVocabulary = try c.decodeIfPresent(String.self, forKey: .customVocabulary)
    }

    public init(
        name: String,
        coverImageName: String?,
        template: String,
        eventVocabulary: String,
        customVocabulary: String?
    ) {
        self.name = name
        self.coverImageName = coverImageName
        self.template = template
        self.eventVocabulary = eventVocabulary
        self.customVocabulary = customVocabulary
    }
}
