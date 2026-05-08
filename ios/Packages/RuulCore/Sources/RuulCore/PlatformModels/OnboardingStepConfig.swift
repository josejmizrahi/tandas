import Foundation

/// One step in the founder onboarding flow. Loaded from
/// `templates.config.onboardingFlow`. The coordinator reads these to drive
/// step transitions; each step's view is wired by `step` discriminator.
public struct OnboardingStepConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String { step }

    public let step: String
    public let order: Int
    public let skippable: Bool

    public init(step: String, order: Int, skippable: Bool) {
        self.step = step
        self.order = order
        self.skippable = skippable
    }
}
