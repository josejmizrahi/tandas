import SwiftUI

/// Convenience wrapper around `.fullScreenCover(...)` that pre-applies the
/// ruul-flavored slide-up transition and a glass-tinted background.
public extension View {
    func ruulFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.fullScreenCover(item: item) { wrapped in
            content(wrapped)
                .background(Color.ruulBackground)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    func ruulFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented) {
            content()
                .background(Color.ruulBackground)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

#if DEBUG
private struct RuulFullScreenCoverPreview: View {
    @State var presented = false

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            RuulButton("Show full-screen cover") { presented = true }
        }
        .ruulFullScreenCover(isPresented: $presented) {
            ZStack {
                RuulMeshBackground(.violet)
                VStack(spacing: RuulSpacing.md) {
                    Text("Full screen")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.primary)
                    RuulButton("Close") { presented = false }
                }
            }
        }
    }
}

#Preview("RuulFullScreenCover") {
    RuulFullScreenCoverPreview()
}
#endif
