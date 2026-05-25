import SwiftUI
import RuulUI
import RuulCore

/// Anonymized vote counts visualization. 3 segments (a favor / en contra
/// / pendientes), proportional widths, with totals on the right. Apple
/// Sports flat — no tinted backgrounds, semantic dots only.
///
/// `thresholdPercent` (optional) renders a thin vertical tick on the bar
/// showing where the "in favor" cumulative share needs to land for the
/// vote to pass. Hidden when nil so callers that don't have threshold
/// data (e.g. legacy fine appeals) keep the bare bar.
public struct VoteCountsBar: View {
    public let counts: VoteCounts
    public let thresholdPercent: Int?

    public init(counts: VoteCounts, thresholdPercent: Int? = nil) {
        self.counts = counts
        self.thresholdPercent = thresholdPercent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    segment(width: ratio(counts.inFavor), color: .green)
                    segment(width: ratio(counts.against), color: .red)
                    segment(width: ratio(counts.pending + counts.abstained), color: Color(.tertiaryLabel))
                }
                .frame(height: 6)
                .clipShape(Capsule())
                .animation(.smooth(duration: 0.5), value: counts.inFavor)
                .animation(.smooth(duration: 0.5), value: counts.against)
                .animation(.smooth(duration: 0.5), value: counts.abstained)

                if let thresholdPercent {
                    thresholdTick(percent: thresholdPercent)
                }
            }
            HStack(spacing: RuulSpacing.md) {
                legendItem(color: .green, label: "A favor", count: counts.inFavor)
                legendItem(color: .red,   label: "En contra", count: counts.against)
                Spacer()
                legendItem(color: Color(.tertiaryLabel),    label: "Pendiente", count: counts.pending)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(counts.inFavor) a favor, \(counts.against) en contra, \(counts.pending) pendientes")
    }

    private func ratio(_ n: Int) -> CGFloat {
        let total = max(1, counts.totalEligible)
        return CGFloat(n) / CGFloat(total)
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            color.frame(width: geo.size.width * width)
        }
    }

    /// Hairline mark at `percent` along the bar's width. Rendered 2pt
    /// taller than the bar on each side so it's visible against any
    /// underlying segment color. The capsule below clips the bar but
    /// not this tick — that's intentional so the marker reads as a
    /// "north line" the bar grows toward.
    private func thresholdTick(percent: Int) -> some View {
        GeometryReader { geo in
            let x = geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100.0
            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 1.5, height: 10)
                .offset(x: x - 0.75, y: -2)
                .accessibilityHidden(true)
        }
        .frame(height: 6)
    }

    private func legendItem(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text("\(count)")
                .font(.footnote.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.primary)
                .contentTransition(.numericText(value: Double(count)))
        }
    }
}
