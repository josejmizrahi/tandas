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

    /// Content body. Events get the hand-crafted `EventInvitesContent`
    /// layout — Apple Invites mold, hero + meta + RSVP + avatar strip +
    /// secondary actions, no card-on-card stacking. Other resource types
    /// stay on the polymorphic catalog-driven stack with `DetailHeaderView`
    /// + `DetailSummaryView` + capability sections.
    private var contentPanel: some View {
        Group {
            if context.usesEventHero {
                EventInvitesContent(context: context)
            } else {
                catalogPanel
            }
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.top, context.hasCoverHero ? RuulSpacing.xl : topInsetWithoutCover)
        .padding(.bottom, RuulSpacing.xxl)
        .background(panelBackground)
    }

    /// Catalog-driven layout for non-event resources. Identity strip +
    /// summary rows + dynamic capability sections. Stays in place so
    /// upcoming slot / fund / asset detail surfaces aren't blocked on
    /// the event redesign.
    private var catalogPanel: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
            DetailHeaderView(context: context)
            DetailSummaryView(context: context)
            DetailAttentionView(context: context)
            DetailActionsBar(context: context)
            dynamicSections
        }
    }

    /// Top padding when the page has no cover. Needs to clear the
    /// floating `DetailTopNavView` (which sits at safe-area top) so the
    /// title block doesn't tuck under it. Approximate the nav row's
    /// vertical footprint — 44pt button + dynamic-island inset.
    private var topInsetWithoutCover: CGFloat {
        RuulSpacing.xxl + 44
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
