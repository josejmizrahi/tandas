import Foundation

/// Beta 1 hide list (W4 items F-4.1 / F-4.2 / F-4.3 / F-4.4).
///
/// The platform supports 6 resource types + multiple presets + a generic
/// vote-creation surface + the full money UI. Most of that is unfinished
/// for end-user polish, so Beta 1 ships with these surfaces hidden behind
/// a single switch:
///
/// - `showAllPresets`            — false → only "Reuniones recurrentes"
///                                  in onboarding's preset picker.
/// - `showAllResourceTypes`      — false → Resources tab + Wizard see
///                                  only `.event` (no asset/slot/fund/…).
/// - `showGenericVoteCreation`   — false → "Crear votación" CTA hidden.
///                                  Appeal-driven votes still work
///                                  because they open via fine flow.
/// - `showFullMoneySurface`      — false → GroupMoneyView swaps to a
///                                  "Próximamente" placeholder.
///
/// All four default to `false` for Beta 1. A developer / TestFlight build
/// can flip them on by editing `current` below or wiring a build setting.
/// Per §7 hide-list and §10 demo readiness in Beta1Consolidation.md.
///
/// Doctrine: this is a beta safety valve, not a permanent feature-flag
/// system. When Beta 1 graduates, the entire struct goes away and the
/// hidden surfaces become first-class.
public struct BetaFeatureFlags: Sendable, Equatable {
    public let showAllPresets: Bool
    public let showAllResourceTypes: Bool
    public let showGenericVoteCreation: Bool
    public let showFullMoneySurface: Bool

    public init(
        showAllPresets: Bool,
        showAllResourceTypes: Bool,
        showGenericVoteCreation: Bool,
        showFullMoneySurface: Bool
    ) {
        self.showAllPresets = showAllPresets
        self.showAllResourceTypes = showAllResourceTypes
        self.showGenericVoteCreation = showGenericVoteCreation
        self.showFullMoneySurface = showFullMoneySurface
    }

    /// Beta 1 invitation mode — everything in the hide list is off.
    public static let beta = BetaFeatureFlags(
        showAllPresets: false,
        showAllResourceTypes: false,
        showGenericVoteCreation: false,
        showFullMoneySurface: false
    )

    /// Fully-unlocked mode for previews, tests, and internal dev builds.
    public static let dev = BetaFeatureFlags(
        showAllPresets: true,
        showAllResourceTypes: true,
        showGenericVoteCreation: true,
        showFullMoneySurface: true
    )

    /// Active configuration for the running app. Beta 1 ships `.beta`.
    /// Tests and previews override via `.dev`.
    public static let current: BetaFeatureFlags = .beta
}
