import SwiftUI

public extension View {
    /// Apply the canonical Ruul sheet chrome to the **content** of a
    /// `.sheet(...)` presentation. Bundles the four modifiers we always
    /// want — drag indicator, big hero corner radius, glass background,
    /// configurable detents — into one line so raw `.sheet { … }` call
    /// sites can match `ruulSheet(...)` without restructuring.
    ///
    /// Example:
    /// ```
    /// .sheet(isPresented: $shown) {
    ///     MyContentView()
    ///         .ruulSheetChrome(detents: [.large])
    /// }
    /// ```
    ///
    /// DS v3 §13.1: sheets are chrome and use Liquid Glass. iOS 26
    /// doesn't expose a glass shape style to `presentationBackground`
    /// yet, so `.ultraThinMaterial` is the most translucent option that
    /// produces the desired blur-and-tint pickup from the parent view.
    func ruulSheetChrome(
        detents: Set<PresentationDetent> = [.medium, .large]
    ) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(RuulRadius.extraLarge)
            .presentationBackground(.ultraThinMaterial)
    }

    /// Convenience wrapper around `.sheet(item:...)` that pre-applies
    /// ruul defaults via `ruulSheetChrome`. Use this for new sheet
    /// callsites; existing call sites can append `.ruulSheetChrome()`
    /// to their content for the same result without restructuring.
    func ruulSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        self.fullScreenCover(item: item) { wrapped in
            content(wrapped).ruulSheetChrome(detents: detents)
        }
    }

    func ruulSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented) {
            content().ruulSheetChrome(detents: detents)
        }
    }
}

#if DEBUG
private struct RuulSheetPreview: View {
    @State var showSheet = false

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.md) {
                RuulButton("Show sheet") { showSheet = true }
            }
        }
        .ruulSheet(isPresented: $showSheet) {
            VStack(spacing: RuulSpacing.md) {
                Capsule()
                    .fill(Color.ruulSeparatorOpaque)
                    .frame(width: 36, height: 4)
                Text("Sheet content")
                    .ruulTextStyle(RuulTypography.title)
                Text("Drag down to dismiss.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulButton("Close", style: .secondary) {}
                Spacer()
            }
            .padding(RuulSpacing.lg)
        }
    }
}

#Preview("RuulSheet") {
    RuulSheetPreview()
}
#endif
