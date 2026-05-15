import SwiftUI
import RuulUI

/// Rounded-corner panel that "slides up" over the cover hero. Holds
/// the scroll content (sections, quick facts, etc.). The cover hero
/// sits behind it ignoring safe area top; the panel's top corners
/// reveal the cover bottom for the Apple Invites visual.
@MainActor
public struct ResourceDetailPanel<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.s6)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: RuulRadius.xl,
                topTrailingRadius: RuulRadius.xl,
                style: .continuous
            )
            .fill(Color.ruulBackgroundCanvas)
        )
        // Pull up to overlap the cover bottom for the slides-up effect.
        .offset(y: -RuulRadius.xl)
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
