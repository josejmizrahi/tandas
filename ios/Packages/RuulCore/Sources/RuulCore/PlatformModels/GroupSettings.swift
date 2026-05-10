import Foundation

/// Strongly-typed view over `groups.settings` jsonb.
///
/// Post BigBang (mig 00078) this is a thin wrapper holding only group-level
/// display preferences. Per OpenPlatform Taxonomy:
///   - vocabulary (eventVocabulary) stays as group preference
///   - frequency / rotation / fines / fund configs migrated OUT:
///       frequency  → ResourceSeries.pattern
///       rotation   → rotation capability config on Resource
///       fines      → basic_fines module config + capability block on Resource
///       fund       → Fund resource type (Phase 3)
///       voting     → groups.governance jsonb
///
/// All fields are optional so a row without a settings backfill — or a
/// future template with a different shape — decodes without errors.
public struct GroupSettings: Sendable, Codable, Hashable {
    /// User-facing word for "event" ("Cena", "Brunch", "Workout", …).
    /// Surfaces in tab labels, copy, and onboarding hints.
    public var eventVocabulary: String?

    public init(eventVocabulary: String? = nil) {
        self.eventVocabulary = eventVocabulary
    }

    public static let empty = GroupSettings()
}
