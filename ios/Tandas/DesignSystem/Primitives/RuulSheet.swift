import SwiftUI

/// Convenience wrapper around `.sheet(...)` that pre-applies ruul defaults:
/// configurable detents, top corner radius, drag indicator visible.
public extension View {
    func ruulSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        self.sheet(item: item) { wrapped in
            content(wrapped)
                .presentationDetents(detents)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(RuulRadius.xl)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    func ruulSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            content()
                .presentationDetents(detents)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(RuulRadius.xl)
                .presentationBackground(.ultraThinMaterial)
        }
    }
}

#if DEBUG
private struct RuulSheetPreview: View {
    @State var showSheet = false

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            VStack(spacing: RuulSpacing.s4) {
                RuulButton("Show sheet") { showSheet = true }
            }
        }
        .ruulSheet(isPresented: $showSheet) {
            VStack(spacing: RuulSpacing.s4) {
                Capsule()
                    .fill(Color.ruulBorderDefault)
                    .frame(width: 36, height: 4)
                Text("Sheet content")
                    .ruulTextStyle(RuulTypography.title)
                Text("Drag down to dismiss.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulButton("Close", style: .secondary) {}
                Spacer()
            }
            .padding(RuulSpacing.s5)
        }
    }
}

#Preview("RuulSheet") {
    RuulSheetPreview()
}
#endif
