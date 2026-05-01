import SwiftUI

/// Skeleton loading view with shimmer animation.
public struct LoadingStateView: View {
    public enum Variant: Sendable, Hashable { case list, card, detail }

    private let variant: Variant
    @State private var phase: CGFloat = -1

    public init(_ variant: Variant = .list) {
        self.variant = variant
    }

    public var body: some View {
        SwiftUI.Group {
            switch variant {
            case .list:   list
            case .card:   card
            case .detail: detail
            }
        }
        .onAppear { startShimmer() }
    }

    private var list: some View {
        VStack(spacing: RuulSpacing.s3) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: RuulSpacing.s3) {
                    skeletonCircle(size: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        skeletonRect(width: 160, height: 14)
                        skeletonRect(width: 100, height: 10)
                    }
                    Spacer()
                }
                .padding(RuulSpacing.s4)
                .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            skeletonRect(width: 200, height: 24)
            skeletonRect(width: .infinity, height: 14)
            skeletonRect(width: .infinity, height: 14)
            skeletonRect(width: 140, height: 14)
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s5) {
            skeletonRect(width: .infinity, height: 200)
            skeletonRect(width: 240, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                skeletonRect(width: .infinity, height: 14)
                skeletonRect(width: .infinity, height: 14)
                skeletonRect(width: 200, height: 14)
            }
        }
    }

    private func skeletonRect(width: CGFloat, height: CGFloat) -> some View {
        Skeleton(phase: phase)
            .frame(maxWidth: width == .infinity ? .infinity : nil)
            .frame(width: width == .infinity ? nil : width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func skeletonCircle(size: CGFloat) -> some View {
        Skeleton(phase: phase)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }

    private func startShimmer() {
        withAnimation(.linear(duration: RuulDuration.shimmerCycle).repeatForever(autoreverses: false)) {
            phase = 2
        }
    }
}

private struct Skeleton: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                Color.ruulBackgroundRecessed
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.30), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(120, width * 0.5))
                .offset(x: phase * (width + 120))
            }
        }
    }
}

#if DEBUG
#Preview("LoadingStateView") {
    ScrollView {
        VStack(spacing: RuulSpacing.s7) {
            Text("List").ruulTextStyle(RuulTypography.footnote)
            LoadingStateView(.list)
            Text("Card").ruulTextStyle(RuulTypography.footnote)
            LoadingStateView(.card)
            Text("Detail").ruulTextStyle(RuulTypography.footnote)
            LoadingStateView(.detail)
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
