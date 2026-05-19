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
/// Activity. `.people` lands in Slice 2A. `.money` follows in Slice 2B.
/// `.connections` (Vínculos) is on the rename/fold queue for Slice 2C —
/// keeping it now so existing routing continues working untouched.
///
/// `.people` is content-gated: the view hides the segment when no
/// section routes here (see UniversalResourceDetailView.visibleTabs).
/// Other tabs preserve their current always-visible behavior.
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case people
    case activity
    case rules
    case connections

    public var id: String { rawValue }

    /// Spanish label for the segmented control. Kept short so the
    /// segments fit a single line on iPhone SE.
    public var label: String {
        switch self {
        case .overview:    return "General"
        case .people:      return "Gente"
        case .activity:    return "Actividad"
        case .rules:       return "Reglas"
        case .connections: return "Vínculos"
        }
    }

    /// SF Symbol used in empty-state cards + (future) per-tab badges.
    /// Not currently rendered inside the segmented control itself —
    /// `RuulSegmentedControl` is label-only.
    public var symbol: String {
        switch self {
        case .overview:    return "doc.text"
        case .people:      return "person.2"
        case .activity:    return "clock.arrow.circlepath"
        case .rules:       return "list.bullet.clipboard"
        case .connections: return "link"
        }
    }
}
