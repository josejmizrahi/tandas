import SwiftUI

/// Animated mesh-gradient background. Three preset variants pulled from
/// `RuulColors`: cool (azules), violet, aqua.
public struct RuulMeshBackground: View {
    public enum Variant: Sendable, Hashable { case cool, violet, aqua }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ruulColors) private var colors

    @State private var phase: CGFloat = 0
    private let variant: Variant

    public init(_ variant: Variant = .cool) {
        self.variant = variant
    }

    public var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(x: 0, y: 0),    .init(x: 0.5, y: 0),    .init(x: 1, y: 0),
                .init(x: 0, y: 0.5),  .init(x: 0.5, y: Float(0.5 + 0.04 * sin(phase))),  .init(x: 1, y: 0.5),
                .init(x: 0, y: 1),    .init(x: 0.5, y: 1),    .init(x: 1, y: 1)
            ],
            colors: paletteFor(variant)
        )
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }

    private func paletteFor(_ variant: Variant) -> [Color] {
        switch variant {
        case .cool:   return colors.meshCool
        case .violet: return colors.meshViolet
        case .aqua:   return colors.meshAqua
        }
    }
}

#if DEBUG
#Preview("RuulMeshBackground — cool") {
    ZStack {
        RuulMeshBackground(.cool)
        Text("Cool mesh")
            .ruulTextStyle(RuulTypography.displayLarge)
            .foregroundStyle(Color.ruulTextPrimary)
    }
}

#Preview("RuulMeshBackground — violet") {
    ZStack {
        RuulMeshBackground(.violet)
        Text("Violet mesh")
            .ruulTextStyle(RuulTypography.displayLarge)
            .foregroundStyle(Color.ruulTextPrimary)
    }
}

#Preview("RuulMeshBackground — aqua") {
    ZStack {
        RuulMeshBackground(.aqua)
        Text("Aqua mesh")
            .ruulTextStyle(RuulTypography.displayLarge)
            .foregroundStyle(Color.ruulTextPrimary)
    }
}
#endif
