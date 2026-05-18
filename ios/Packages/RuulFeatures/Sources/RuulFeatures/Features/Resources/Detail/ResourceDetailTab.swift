import Foundation

/// The 4 universal tabs every resource detail screen shows. Per-type
/// tabs extend this by introducing a `ResourceTabRegistry` that returns
/// ordered tabs per `ResourceType` — the universal 4 stay as canonical.
///
/// Mapped to sections via `CapabilitySection.tabId`. The string match is
/// `tab.id == section.tabId`. Sections without an explicit tabId default
/// to `.overview`.
///
/// Doctrine: there is no "Gobierno"/capabilities tab. Capabilities are
/// auto-on at resource creation and never user-visible. Sections appear
/// when the user takes an action that needs them.
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case connections

    public var id: String { rawValue }

    /// Spanish label for the segmented control. "Vínculos" instead of
    /// "Conexiones" so the four segments fit a single line on iPhone SE.
    public var label: String {
        switch self {
        case .overview:    return "General"
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
        case .activity:    return "clock.arrow.circlepath"
        case .rules:       return "list.bullet.clipboard"
        case .connections: return "link"
        }
    }
}
