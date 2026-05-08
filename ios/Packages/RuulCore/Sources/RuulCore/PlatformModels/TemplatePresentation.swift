import Foundation

/// User-facing presentation metadata for a template — display name, icon,
/// long copy, bullets, and the default vocabulary used when the template
/// instantiates a Group/Resource.
///
/// Persisted as `templates.config.presentation` jsonb. Audit doc § 5.3
/// item 7c moves legacy group-type presentation data into `Template`, so
/// a template is the single source of truth for how it shows up in
/// onboarding and elsewhere.
///
/// Optional everywhere because:
///   - Old DB rows (pre-migration 00037) lack the field; decoders
///     fall back to `Template.name`/`Template.description`/`Template.icon`.
///   - Placeholder templates may decline to provide all fields.
public struct TemplatePresentation: Sendable, Codable, Hashable {
    /// Short display name (e.g. "Cena recurrente"). Falls back to
    /// `Template.name` when absent.
    public let displayName: String?

    /// SF Symbol name (e.g. "fork.knife"). Falls back to `Template.icon`.
    public let symbolName: String?

    /// One-line descriptive copy (e.g. "Cenas que rotan host con multas
    /// automáticas..."). Falls back to `Template.description`.
    public let description: String?

    /// Bulleted highlights shown in the template selector and onboarding
    /// info screens (3–5 short phrases).
    public let bullets: [String]?

    /// Default per-resource label for groups created from this template
    /// (e.g. "Cena", "Tanda", "Partido"). Used as the seed for
    /// `groups.event_label` if onboarding doesn't ask for an override.
    public let defaultEventLabel: String?

    public init(
        displayName: String? = nil,
        symbolName: String? = nil,
        description: String? = nil,
        bullets: [String]? = nil,
        defaultEventLabel: String? = nil
    ) {
        self.displayName = displayName
        self.symbolName = symbolName
        self.description = description
        self.bullets = bullets
        self.defaultEventLabel = defaultEventLabel
    }
}
