import SwiftUI
import RuulCore

/// One section of a Resource Detail page. Each section is owned by a
/// capability id (or set of ids). When the resource has the capability
/// enabled, the registry includes the section; otherwise it's omitted.
///
/// Sections are intentionally rendered as `AnyView` here rather than via
/// an associatedtype protocol — it keeps the registry homogeneous and
/// keeps the call site (`ForEach(sections)`) cheap. Per-section state
/// lives in its own SwiftUI view, not in this struct.
public struct CapabilitySection: Identifiable {
    /// Stable id used for diffing + analytics. Conventionally the
    /// capability id this section was authored for (e.g. "rsvp", "money",
    /// "rules", "schedule"). Multiple sections can share a capability if
    /// their content is distinct (e.g. "rules.list" + "rules.proposeChange").
    public let id: String

    /// Lower priority renders higher on the page. Convention:
    ///   100 schedule / hero meta
    ///   200 rsvp
    ///   300 participants / guests / members
    ///   400 money
    ///   500 slots / bookings / assignments
    ///   600 rotation
    ///   700 voting
    ///   800 rules
    ///   900 activity
    /// Activity / Rules anchor the bottom of the dynamic stack; the
    /// outer ResourceDetailView still keeps Settings as the very last
    /// zone after the dynamic sections finish.
    public let priority: Int

    /// Predicate: does the resource's enabled-capability set include the
    /// inputs that activate this section? Allowed to OR multiple
    /// capability ids — e.g. money is enabled by `money`, `expenses`,
    /// `contributions`, or `payouts`. Receives the resource's actual
    /// enabled set so renderers stay declarative.
    public let isEnabledFor: (Set<String>) -> Bool

    /// Body. Caller passes the assembled context. Returning AnyView is
    /// idiomatic for a runtime-composed registry — each renderer is
    /// trivially small (most ~30-100 LoC) so type-erasure cost is nil.
    public let render: (ResourceDetailContext) -> AnyView

    public init(
        id: String,
        priority: Int,
        isEnabledFor: @escaping (Set<String>) -> Bool,
        render: @escaping (ResourceDetailContext) -> AnyView
    ) {
        self.id = id
        self.priority = priority
        self.isEnabledFor = isEnabledFor
        self.render = render
    }
}

/// Static registry of every section the app knows how to render. Each
/// section registers itself once at boot; the ResourceDetailView reads
/// `sectionsFor(enabledCapabilities:)` per resource.
///
/// V1 is hardcoded — Phase 2 can spin this off into a plugin-style
/// registration if third-party capabilities ever land. For now,
/// `CapabilitySectionCatalog.shared` is the single source of truth.
@MainActor
public final class CapabilitySectionCatalog {
    public static let shared = CapabilitySectionCatalog()

    private var sections: [String: CapabilitySection] = [:]
    private init() {
        registerDefaults()
    }

    public func register(_ section: CapabilitySection) {
        sections[section.id] = section
    }

    /// All sections whose `isEnabledFor` predicate matches the supplied
    /// capability set, sorted by priority ascending (so smaller priority
    /// renders first / on top).
    public func sectionsFor(enabledCapabilities: Set<String>) -> [CapabilitySection] {
        sections.values
            .filter { $0.isEnabledFor(enabledCapabilities) }
            .sorted { $0.priority < $1.priority }
    }

    /// Hook for `registerDefaults`. Splits the actual registration calls
    /// into the per-section files (`Sections/*.swift`) so the catalog
    /// itself stays a thin container — each section owns its own
    /// `static let definition: CapabilitySection`.
    private func registerDefaults() {
        register(ScheduleSectionView.definition)
        register(CapacityProgressSectionView.definition)
        register(LocationSectionView.definition)
        register(DescriptionSectionView.definition)
        register(RSVPSectionView.definition)
        register(CheckInSectionView.definition)
        register(HostActionsSectionView.definition)
        register(MoneySectionView.definition)
        register(RotationSectionView.definition)
        register(RulesSectionView.definition)
        register(ActivitySectionView.definition)
    }
}
