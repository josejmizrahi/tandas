import SwiftUI
import RuulUI
import RuulCore

/// Universal, capability-driven resource detail page. Sections render
/// dynamically based on which capabilities the resource has enabled —
/// no per-type branching anywhere in this view.
///
/// Composition (top → bottom):
///   1. Cover         — optional parallax hero (events + any resource with a cover)
///   2. Header        — identity (icon + name + type + status pill)
///   3. Attention     — inbox actions filtered to this resource
///   4. Summary       — 2-3 key facts (type-aware metadata)
///   5. Actions       — capability-driven CTA strip
///   6. Sections      — DynamicSectionRenderer over the catalog
///
/// Two chrome layers sit on top of the scroll content:
///   - `DetailTopNavView`        — floating glass nav (close, share, more menu)
///   - `DetailStickyFooterView`  — bottom-pinned CTA via `safeAreaInset`
///
/// `ResourceDetailContext` is the single argument every zone + section
/// reads from. Event-aware sections additionally consume
/// `\.eventInteractor` + `\.eventDetailPresenter` from the environment.
public struct UniversalResourceDetailView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.ruulBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    if context.hasCoverHero {
                        DetailCoverView(
                            imageURL: context.coverImageURL,
                            fallbackCoverName: context.coverImageName
                        )
                    }
                    contentPanel
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: context.hasCoverHero ? .top : [])
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DetailStickyFooterView()
            }

            DetailTopNavView(context: context)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Padded VStack that hosts every zone below the cover. When a cover
    /// is present, the panel pulls up under it via an `UnevenRoundedRectangle`
    /// so the cover bottom is visually masked into a soft curve. When there's
    /// no cover, the panel renders flush against the safe-area top.
    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
            DetailHeaderView(context: context)
            DetailAttentionView(context: context)
            DetailSummaryView(context: context)
            DetailActionsBar(context: context)

            dynamicSections
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.top, context.hasCoverHero ? RuulSpacing.xl : RuulSpacing.md)
        .padding(.bottom, RuulSpacing.xxl)
        .background(panelBackground)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if context.hasCoverHero {
            // Pulls the rounded panel up under the cover bottom by its own
            // corner radius — the bottom of the cover disappears into the
            // curve. Matches the legacy EventDetailView treatment 1:1.
            UnevenRoundedRectangle(
                topLeadingRadius: RuulRadius.extraLarge,
                topTrailingRadius: RuulRadius.extraLarge,
                style: .continuous
            )
            .fill(Color.ruulBackground)
            .offset(y: -RuulRadius.extraLarge)
        } else {
            Color.ruulBackground
        }
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

#if DEBUG
#Preview("Event — guest viewer") {
    Text("UniversalResourceDetailView needs AppState + AppState-bound repos to render the dynamic section catalog. See `EventDetailHostShowcase` in the showcase target for a wired live preview.")
        .multilineTextAlignment(.center)
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
