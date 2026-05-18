import Foundation

/// Typed namespace for rule scope strings. Mirrors the `p_scope` jsonb
/// value the platform expects on every rule write — `{ type: "group" }`,
/// `{ type: "resource", id }`, `{ type: "series", id }`, etc.
///
/// **Why this exists:** scope strings were sprinkled as raw string
/// literals across `RuleShape.validScopes`, `GroupPolicy.targetScope`,
/// `RuleTemplate` JSON envelopes, and `RuleTemplateRepository.scopeHint`
/// (25+ call sites). A typo (`"reource"` instead of `"resource"`)
/// silently shipped a rule the engine couldn't match. Per
/// Plans/Active/CleanupAudit_2026-05-18 §05.8.
///
/// **Source of truth:** the 6 values below match the platform-canonical
/// scope vocabulary documented in Plans/Active/RuleEngineDoctrine.md and
/// enforced by the engine's `selectMostSpecificPerSlug` precedence
/// (occurrence > resource > series > resource_type > group >
/// global_default).
///
/// Pattern matches `CapabilityID` (Capabilities/CapabilityID.swift) and
/// `RsvpAction.Status` (PlatformModels/RsvpAction.swift) — caseless enum
/// used as a namespace for typed string constants.
public enum RuleScope {
    /// `global_default` — applies platform-wide. Lowest precedence.
    public static let globalDefault = "global_default"
    /// `group` — applies to every resource in the group. Default scope
    /// for `GroupPolicy.targetScope`.
    public static let group         = "group"
    /// `resource_type` — applies to every resource of a given type
    /// inside the group (e.g. every fund, every event series).
    public static let resourceType  = "resource_type"
    /// `series` — applies to every occurrence of a recurring resource
    /// series (events with `series_id`, slot windows with the same
    /// generator).
    public static let series        = "series"
    /// `resource` — applies to one specific resource (one event, one
    /// fund, one asset). Higher precedence than series.
    public static let resource      = "resource"
    /// `occurrence` — applies to one occurrence of a recurring series
    /// (most specific scope, wins precedence).
    public static let occurrence    = "occurrence"

    /// Every scope identifier declared above. Used by tests to detect
    /// drift between the namespace and consumer call sites.
    public static let all: Set<String> = [
        globalDefault, group, resourceType, series, resource, occurrence,
    ]
}
