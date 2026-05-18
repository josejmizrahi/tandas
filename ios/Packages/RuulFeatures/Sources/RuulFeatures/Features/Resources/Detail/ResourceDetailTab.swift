import Foundation

/// The 5 universal tabs every resource detail screen shows in Pass 1.
/// Per-type tabs (Pass 2) extend this by introducing a `ResourceTabRegistry`
/// that returns ordered tabs per `ResourceType` — the universal 5 stay as
/// the canonical baseline.
///
/// Mapped to sections via `CapabilitySection.tabId`. The string match is
/// `tab.id == section.tabId`. Sections without an explicit tabId default
/// to `.overview`.
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case connections
    case governance

    public var id: String { rawValue }

    /// Spanish label for the segmented control. Kept short ("Gobierno"
    /// not "Gobernanza") so 5 segments fit on iPhone SE width.
    public var label: String {
        switch self {
        case .overview:    return "General"
        case .activity:    return "Actividad"
        case .rules:       return "Reglas"
        case .connections: return "Conexiones"
        case .governance:  return "Gobierno"
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
        case .governance:  return "shield"
        }
    }
}
