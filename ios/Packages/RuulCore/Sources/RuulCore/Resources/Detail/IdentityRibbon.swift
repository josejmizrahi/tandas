import SwiftUI

/// Identity layer payload — compact ribbon at the top of every Resource
/// Detail. Carries type metadata (icon, color, family label) so the
/// renderer can draw the chrome WITHOUT branching on resource_type.
/// Builders decide what this contains; the view just renders.
public struct IdentityRibbon: Sendable, Hashable {
    /// SF Symbol name.
    public let icon: String
    /// Semantic tint for the icon. Sendable wrapper around a chosen
    /// resource-family color (see `ResourceFamilyTint`).
    public let tint: ResourceFamilyTint
    /// Resource title — the user's name for this thing.
    public let title: String
    /// Short subtitle line: "Event · Scheduled · Tomorrow 20:00"
    public let subtitleSegments: [String]

    public init(icon: String, tint: ResourceFamilyTint, title: String, subtitleSegments: [String]) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitleSegments = subtitleSegments
    }
}

/// Canonical tints per resource family. Sendable + Hashable so it can
/// ride inside the block tree across actors. The View resolves these
/// to `Color` at render time (see `ResourceFamilyTint+Color.swift`
/// in RuulUI). Builders pick one; the View never asks "what type is this".
public enum ResourceFamilyTint: String, Sendable, Hashable, CaseIterable {
    case events
    case funds
    case votes
    case fines
    case agreements
    case assets
    case persons
    case neutral
}
