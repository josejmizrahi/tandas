import Foundation

/// The universal tabs every resource detail screen shows. Per-type
/// tabs extend this by introducing a `ResourceTabRegistry` that returns
/// ordered tabs per `ResourceType` — the canonical set stays here.
///
/// Mapped to sections via `CapabilitySection.tabId`. The string match is
/// `tab.id == section.tabId`. Sections without an explicit tabId default
/// to `.overview`.
///
/// Doctrine (Plans/Active/HumanLayerSimplification.md §A.1, §C.1):
/// canonical 5 user-facing concepts are Things / People / Money / Rules /
/// Activity. `.people` landed in Slice 2A; `.money` in Slice 2B. `.connections`
/// label changed to "Relacionado" in Slice 2C (the word "Vínculo" is on
/// the forbidden-vocab list — it exposes the resource_links graph model).
///
/// Content-gated tabs (hidden when no section routes here):
///   - `.people`      (Slice 2A)
///   - `.money`       (Slice 2B)
///   - `.connections` (Slice 2C)
/// Other tabs preserve their current always-visible behavior.
/// See UniversalResourceDetailView.visibleTabs for the predicate.
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case people
    case money
    case activity
    case rules
    case connections

    public var id: String { rawValue }

    /// Spanish label for the segmented control. Kept short so the
    /// segments fit a single line on iPhone SE. Also surfaced as
    /// accessibilityLabel in icon-only mode (current default for
    /// Resource Detail), so VoiceOver readability matters even when
    /// the text isn't visually rendered.
    public var label: String {
        switch self {
        case .overview:    return "General"
        case .people:      return "Gente"
        case .money:       return "Dinero"
        case .activity:    return "Actividad"
        case .rules:       return "Reglas"
        case .connections: return "Relacionado"
        }
    }

    /// SF Symbol used in empty-state cards + (future) per-tab badges.
    /// Not currently rendered inside the segmented control itself —
    /// `RuulSegmentedControl` is label-only.
    public var symbol: String {
        switch self {
        case .overview:    return "doc.text"
        case .people:      return "person.2"
        case .money:       return "banknote"
        case .activity:    return "clock.arrow.circlepath"
        case .rules:       return "list.bullet.clipboard"
        case .connections: return "link"
        }
    }
}
