import SwiftUI
import RuulUI

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
                .presentationCornerRadius(RuulRadius.extraLarge)
                // DS v3 §13.1: sheets son chrome, deben usar Liquid Glass.
                // iOS 26 no expone una variante glass de `presentationBackground`
                // (solo acepta ShapeStyle: `.regularMaterial`/`.ultraThinMaterial`).
                // `.ultraThinMaterial` es el material más translúcido disponible
                // y produce el efecto deseado para sheets sobre el contenido.
                // TODO DS §13: swap a glass nativo cuando SwiftUI lo exponga.
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
                .presentationCornerRadius(RuulRadius.extraLarge)
                // DS v3 §13.1: sheets son chrome, deben usar Liquid Glass.
                // iOS 26 no expone una variante glass de `presentationBackground`
                // (solo acepta ShapeStyle: `.regularMaterial`/`.ultraThinMaterial`).
                // `.ultraThinMaterial` es el material más translúcido disponible
                // y produce el efecto deseado para sheets sobre el contenido.
                // TODO DS §13: swap a glass nativo cuando SwiftUI lo exponga.
                .presentationBackground(.ultraThinMaterial)
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
