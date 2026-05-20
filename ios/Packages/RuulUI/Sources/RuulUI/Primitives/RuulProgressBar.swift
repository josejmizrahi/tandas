import SwiftUI

/// Progress bar primitive. Linear (continuous) or stepped variant.
public struct RuulProgressBar: View {
    public enum Style: Sendable, Hashable { case linear, steps(Int) }

    private let value: Double  // 0...1
    private let style: Style
    private let height: CGFloat

    public init(value: Double, style: Style = .linear, height: CGFloat = 6) {
        self.value = max(0, min(1, value))
        self.style = style
        self.height = height
    }

    public var body: some View {
        switch style {
        case .linear:
            linearBar
        case .steps(let count):
            steppedBar(count: count)
        }
    }

    private var linearBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.ruulBackgroundRecessed)
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.ruulAccent, Color.ruulAccentSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(height, geo.size.width * value))
                    .animation(.ruulSmooth, value: value)
            }
        }
        .frame(height: height)
    }

    private func steppedBar(count: Int) -> some View {
        let activeCount = max(0, min(count, Int((Double(count) * value).rounded())))
        return HStack(spacing: RuulSpacing.xxs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index < activeCount ? Color.ruulAccent : Color.ruulBackgroundRecessed)
                    .frame(height: height)
                    .animation(.ruulSmooth.delay(Double(index) * 0.04), value: activeCount)
            }
        }
    }
}

#if DEBUG
private struct RuulProgressBarPreview: View {
    @State var value = 0.4

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Linear")
                .font(.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
            RuulProgressBar(value: value)
            RuulProgressBar(value: value, height: 4)
            RuulProgressBar(value: 1.0)

            Text("Stepped")
                .font(.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
            RuulProgressBar(value: value, style: .steps(5))
            RuulProgressBar(value: 0.6, style: .steps(3))

            Slider(value: $value, in: 0...1)
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulProgressBar") {
    RuulProgressBarPreview()
}
#endif
