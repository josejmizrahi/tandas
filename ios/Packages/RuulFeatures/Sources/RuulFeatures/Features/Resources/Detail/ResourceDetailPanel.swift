import SwiftUI
import RuulUI

/// Rounded-corner panel that "slides up" over the cover hero. Holds
/// the scroll content (sections, quick facts, etc.). The cover hero
/// sits behind it ignoring safe area top; the panel's top corners
/// reveal the cover bottom for the Apple Invites visual.
///
/// Background can be a solid canvas (legacy) or `.ultraThinMaterial`
/// (Luma ambient — when the detail screen renders a tinted bg from
/// the cover palette behind everything, the glass material lets that
/// tint bleed through the panel).
@MainActor
public struct ResourceDetailPanel<Content: View>: View {
    public enum Surface: Sendable, Hashable {
        case canvas
        case ambientGlass
    }

    let surface: Surface
    let content: Content

    public init(
        surface: Surface = .ambientGlass,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.s6)
        .background(panelBackground)
        // Pull up to overlap the cover bottom for the slides-up effect.
        .offset(y: -RuulRadius.xl)
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: RuulRadius.xl,
            topTrailingRadius: RuulRadius.xl,
            style: .continuous
        )
        switch surface {
        case .canvas:
            shape.fill(Color.ruulBackgroundCanvas)
        case .ambientGlass:
            // ultraThinMaterial: blurs whatever ambient bg the parent
            // is rendering and tints it slightly toward the system
            // surface. Cards inside the panel (RSVP, Money, Rules)
            // keep their `ruulSurface` opaque fill so they stay
            // readable against the glass.
            shape.fill(.ultraThinMaterial)
        }
    }
}

#if DEBUG
#Preview("Panel over cover") {
    ZStack(alignment: .top) {
        Color.green.frame(height: 360)
        VStack(spacing: 0) {
            Spacer().frame(height: 280)
            ResourceDetailPanel {
                VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                    Text("Section A").ruulTextStyle(RuulTypography.subheadSemibold)
                    Text("Section B").ruulTextStyle(RuulTypography.body)
                    Text("Section C").ruulTextStyle(RuulTypography.body)
                }
                .padding(.horizontal, RuulSpacing.s6)
            }
        }
    }
    .ignoresSafeArea()
}
#endif
