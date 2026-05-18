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
    ///   100-150 schedule / capacity / location / description (canonical, inline)
    ///   160-166 type-specific bespoke (asset.custody, space.capacity, ...)
    ///   200 rsvp
    ///   250 check_in
    ///   300 participants / guests / members
    ///   350 host_actions
    ///   400 money
    ///   500 slots / bookings / assignments
    ///   600 rotation
    ///   700 voting
    ///   800 rules
    ///   850 resource_links / event-uses-resources
    ///   900 activity
    /// Activity / Rules anchor the bottom of the dynamic stack; the
    /// outer ResourceDetailView still keeps Settings as the very last
    /// zone after the dynamic sections finish.
    public let priority: Int

    /// Which tab this section renders inside. Default "overview" matches
    /// pre-Pass-1 behavior (everything stacked in one scroll). Sections
    /// that move tabs declare their target explicitly. The string is
    /// matched against `ResourceDetailTab.id`.
    public let tabId: String

    /// Predicate: does the resource's enabled-capability set include the
    /// inputs that activate this section? Allowed to OR multiple
    /// capability ids — e.g. money is enabled by `money`, `expenses`,
    /// `contributions`, or `payouts`. Receives the resource's actual
    /// enabled set so renderers stay declarative.
    public let isEnabledFor: (Set<String>) -> Bool

    /// Optional second predicate that runs AFTER `isEnabledFor` passes.
    /// Receives the full `ResourceDetailContext` so sections can gate on
    /// non-capability signals — resource type (asset-only sections),
    /// metadata presence (description with empty body), member directory
    /// completeness, etc. `nil` means "always visible if isEnabledFor
    /// passes". Per UniversalRuleTemplates §14 doctrine-alignment: move
    /// type checks OUT of the view's body and INTO the section's own
    /// definition where the type-knowledge belongs.
    public let isVisibleFor: ((ResourceDetailContext) -> Bool)?

    /// Body. Caller passes the assembled context. Returning AnyView is
    /// idiomatic for a runtime-composed registry — each renderer is
    /// trivially small (most ~30-100 LoC) so type-erasure cost is nil.
    public let render: (ResourceDetailContext) -> AnyView

    public init(
        id: String,
        priority: Int,
        tabId: String = "overview",
        isEnabledFor: @escaping (Set<String>) -> Bool,
        isVisibleFor: ((ResourceDetailContext) -> Bool)? = nil,
        render: @escaping (ResourceDetailContext) -> AnyView
    ) {
        self.id = id
        self.priority = priority
        self.tabId = tabId
        self.isEnabledFor = isEnabledFor
        self.isVisibleFor = isVisibleFor
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
    /// renders first / on top). Capability-only filter — sections that
    /// also need context-aware gating (resource type, metadata presence)
    /// should call the `sectionsFor(context:)` variant below.
    public func sectionsFor(enabledCapabilities: Set<String>) -> [CapabilitySection] {
        sections.values
            .filter { $0.isEnabledFor(enabledCapabilities) }
            .sorted { $0.priority < $1.priority }
    }

    /// Same as above but ALSO runs each section's `isVisibleFor` predicate
    /// (when present) against the full context. Sections with `isVisibleFor
    /// == nil` are treated as universally visible (subject only to caps).
    /// This is the canonical entry point now that bespoke type-aware
    /// sections live in the catalog — the view should call this variant
    /// when it has a context available.
    public func sectionsFor(context: ResourceDetailContext) -> [CapabilitySection] {
        sections.values
            .filter { $0.isEnabledFor(context.enabledCapabilities) }
            .filter { $0.isVisibleFor?(context) ?? true }
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

        // Bespoke type-aware sections (priority 150-156). Each gates on
        // resource type via `isVisibleFor`. Consumed by the view's
        // bespoke-catalog ForEach above the canonical inline sections.
        register(AssetCustodySection.definition)
        register(AssetOwnershipSection.definition)
        register(AssetMaintenanceSection.definition)
        register(AssetBookingsSection.definition)
        register(SpaceCapacitySection.definition)
        register(SpaceOccupancySection.definition)
        register(SpaceBookingsSection.definition)
        register(FundBalanceSection.definition)
        register(ResourcesUsedSectionView.definition)

        // Stub sections (Sections/Stubs/). Backend wiring lands per
        // capability; until then they render minimal cards (real data
        // when present in metadata, "Próximamente" otherwise) so an
        // enabled capability never silently disappears from the page.
        register(StatusSectionView.definition)
        register(RecurrenceSectionView.definition)
        register(DeadlineSectionView.definition)
        register(ExpirationSectionView.definition)
        register(ParticipantsSectionView.definition)
        register(AttendanceSectionView.definition)
        register(GuestAccessSectionView.definition)
        register(AssignmentSectionView.definition)
        register(BookingSectionView.definition)
        register(ValuationSectionView.definition)
        register(InventorySectionView.definition)
        register(AccessSectionView.definition)
        register(DelegationSectionView.definition)
        register(VotingSectionView.definition)
        register(ApprovalSectionView.definition)
        register(AppealSectionView.definition)
        register(ConsequenceSectionView.definition)
        register(SwapSectionView.definition)
        register(CancellationSectionView.definition)
        register(ReminderSectionView.definition)
        register(HistorySectionView.definition)
    }
}
