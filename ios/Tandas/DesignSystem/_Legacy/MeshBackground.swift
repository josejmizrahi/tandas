import SwiftUI

struct MeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(x: 0, y: 0),    .init(x: 0.5, y: 0),    .init(x: 1, y: 0),
                .init(x: 0, y: 0.5),  .init(x: 0.5, y: Float(0.5 + 0.04 * sin(phase))),  .init(x: 1, y: 0.5),
                .init(x: 0, y: 1),    .init(x: 0.5, y: 1),    .init(x: 1, y: 1)
            ],
            colors: Brand.meshColors
        )
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}
