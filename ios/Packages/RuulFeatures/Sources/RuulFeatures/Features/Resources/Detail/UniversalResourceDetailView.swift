import SwiftUI
import RuulUI
import RuulCore

/// Universal, capability-driven resource detail page. Sections render
/// dynamically based on which capabilities the resource has enabled —
/// no per-type branching anywhere in this view.
///
/// Composition (top → bottom):
///   1. Header     — identity (icon + name + type + status pill + more menu)
///   2. Attention  — inbox actions filtered to this resource
///   3. Summary    — 2-3 key facts (type-aware metadata)
///   4. Actions    — capability-driven CTA strip
///   5. Sections   — DynamicSectionRenderer over the catalog
///   6. Settings   — rename, archive, enable capability (TODO V2)
///
/// `ResourceDetailContext` is the single argument every zone + section
/// reads from. The caller owns presentation of sub-sheets (ledger,
/// rules, edit) via the closures wired into the context.
public struct UniversalResourceDetailView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                DetailHeaderView(context: context)
                DetailAttentionView(context: context)
                DetailSummaryView(context: context)
                DetailActionsBar(context: context)

                dynamicSections
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.xxl)
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
    }

    /// Renders every capability-driven section in priority order. Tries
    /// to avoid empty visual noise: each section is responsible for its
    /// own loading / empty state, but we don't add any section unless
    /// the catalog's predicate matches.
    @ViewBuilder
    private var dynamicSections: some View {
        let sections = CapabilitySectionCatalog.shared
            .sectionsFor(enabledCapabilities: context.enabledCapabilities)
        ForEach(sections) { section in
            section.render(context)
        }
    }
}
