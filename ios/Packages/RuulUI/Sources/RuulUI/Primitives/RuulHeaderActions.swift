import SwiftUI

/// Container que agrupa N pill buttons en una sola pill compartida.
/// Per DS doc §3.4.
public struct RuulHeaderActions<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .ruulGlass(Capsule(), material: .regular)
    }
}

#if DEBUG
#Preview("RuulHeaderActions") {
    HStack {
        Button { } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.glass)
            .accessibilityLabel("Atrás")
        Spacer()
        RuulHeaderActions {
            Button { } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .accessibilityLabel("Buscar")
            Button { } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.plain)
                .accessibilityLabel("Más")
        }
    }
    .padding(RuulSpacing.md)
    .background(Color.ruulBackground)
}
#endif
