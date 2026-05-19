import Foundation

/// The 6 universal tabs every resource detail screen can show. Per the
/// V2 Human-Layer doctrine (Plans/Active/ProductCompression.md §H.2):
///
///   General · Gente · Dinero · Reglas · Actividad · Relacionado
///
/// General, Reglas, Actividad are always rendered. Gente, Dinero, and
/// Relacionado are content-gated: the host view hides them silently
/// when their section catalog yields zero sections for the current
/// resource. Same gating model that already governs stubs.
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
    case people
    case money
    case rules
    case activity
    case connections

    public var id: String { rawValue }

    /// Spanish label for the segmented control. "Relacionado" replaces
    /// the old "Vínculos" (graph-model leak) per V1 §C.1 Option A. The
    /// host hides this tab when empty so the typical resource shows
    /// 3-5 tabs, not 6.
    public var label: String {
        switch self {
        case .overview:    return "General"
        case .people:      return "Gente"
        case .money:       return "Dinero"
        case .rules:       return "Reglas"
        case .activity:    return "Actividad"
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
        case .money:       return "dollarsign.circle"
        case .rules:       return "list.bullet.clipboard"
        case .activity:    return "clock.arrow.circlepath"
        case .connections: return "link"
        }
    }
}
