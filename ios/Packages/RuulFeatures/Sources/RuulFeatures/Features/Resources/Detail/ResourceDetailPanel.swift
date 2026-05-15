import SwiftUI
import RuulUI

/// Vertical container for the detail screen's section stack. Pure
/// content scaffolding — no chrome, no offset, no background.
///
/// Visual ownership shifted in the 2026-05-15 Luma refresh: the cover
/// hero is now a discrete rounded card with margins on all four sides,
/// so the panel no longer "slides up" to overlap it. Sections render
/// directly on the screen's ambient palette layer; opaque section
/// cards (RSVP / Money / Rules) provide their own definition.
///
/// The `Surface` parameter is kept for source-compat with call sites
/// that still pass it (`.ambientGlass`) — both cases now render the
/// same transparent container. The param will go away in a future
/// cleanup once callers drop it.
@MainActor
public struct ResourceDetailPanel<Content: View>: View {
    public enum Surface: Sendable, Hashable {
        case canvas
        case ambientGlass
    }

    let content: Content

    public init(
        surface: Surface = .ambientGlass,
        @ViewBuilder content: () -> Content
    ) {
        _ = surface  // legacy — kept for source-compat; see type doc
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.lg)
    }
}

#if DEBUG
#Preview("Panel over ambient") {
    ZStack {
        Color.ruulBackgroundCanvas.ignoresSafeArea()
        VStack(spacing: 0) {
            Spacer().frame(height: 200)
            ResourceDetailPanel {
                VStack(alignment: .leading, spacing: RuulSpacing.md) {
                    Text("Section A").ruulTextStyle(RuulTypography.subheadSemibold)
                    Text("Section B").ruulTextStyle(RuulTypography.body)
                    Text("Section C").ruulTextStyle(RuulTypography.body)
                }
                .padding(.horizontal, RuulSpacing.lg)
            }
        }
    }
}
#endif
