import SwiftUI
import RuulUI
import RuulCore

/// Universal, capability-driven resource detail page. Composed per the
/// canonical Resource Detail spec:
///
///   1. Cover (optional)         — parallax hero when an image URL exists
///   2. Header                   — identity (`EventHeroTitleBlock` for events,
///                                  `DetailHeaderView` for other types)
///   3. Summary                  — `ResourceSummaryView`, capability-driven
///                                  across every resource type
///   4. Needs Attention          — inbox actions filtered to this resource
///   5. Primary Actions          — top CTA (RSVP intent for events)
///   6. Secondary Actions strip  — money-flavored chips (Gasto / Aportación / Payout)
///   7. Dynamic Sections         — catalog-registered, gated by capabilities
///       (RSVP attendees, CheckIn, HostActions, Money, Rules, Activity)
///
/// Two chrome layers sit on top of the scroll content:
///   - `DetailTopNavView`        — floating glass nav (close, share, more menu)
///   - `DetailStickyFooterView`  — bottom-pinned CTA via `safeAreaInset`
public struct UniversalResourceDetailViewLegacy: View {
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

    /// Single canonical content stack. Identity + Summary swap based on
    /// resource type; everything below is shared across types so non-event
    /// resources benefit from the same ordering when their detail surfaces
    /// land.
    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
            identityZone
            summaryZone
            DetailAttentionView(context: context)
            DetailPrimaryActions(context: context)
            DetailActionsBar(context: context)
            dynamicSections
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.top, context.hasCoverHero ? RuulSpacing.xl : topInsetWithoutCover)
        .padding(.bottom, RuulSpacing.xxl)
        .background(panelBackground)
    }

    @ViewBuilder
    private var identityZone: some View {
        if context.usesEventHero {
            EventHeroTitleBlock(context: context)
        } else {
            DetailHeaderView(context: context)
        }
    }

    @ViewBuilder
    private var summaryZone: some View {
        // AppShell 2026-05-12: single capability-driven summary view across
        // every resource type. Replaces the per-type branch (EventStatusSummary
        // for events / DetailSummaryView for others) per memoria
        // `project_resource_detail_capability_driven`.
        ResourceSummaryView(context: context)
    }

    /// Top padding when no cover is present. Clears the floating
    /// `DetailTopNavView` (which sits at safe-area top) so the title
    /// block doesn't tuck under it.
    private var topInsetWithoutCover: CGFloat {
        RuulSpacing.xxl + 44
    }

    @ViewBuilder
    private var panelBackground: some View {
        if context.hasCoverHero {
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
    Text("UniversalResourceDetailViewLegacy needs AppState + AppState-bound repos to render the dynamic section catalog. See `EventDetailHostShowcase` in the showcase target for a wired live preview.")
        .multilineTextAlignment(.center)
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
