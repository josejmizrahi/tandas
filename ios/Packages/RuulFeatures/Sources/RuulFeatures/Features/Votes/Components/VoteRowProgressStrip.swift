import SwiftUI
import RuulUI
import RuulCore

/// Compact one-line vote progress preview used inside list rows
/// (OpenVotesListView, group pendings, inbox). Composes:
///   - 14pt quorum ring (mini variant of `VoteMetricsTile`'s 22pt ring)
///   - 4pt tally bar with threshold tick
///   - quorum count (cast/required) on the right
///
/// Designed to live inside the existing row card without adding chrome.
/// No countdown — the row already carries "Cierra X". This strip is
/// the visual heartbeat that text alone can't deliver.
struct VoteRowProgressStrip: View {
    let closesAt: Date
    let quorumPercent: Int
    let thresholdPercent: Int
    let counts: VoteCounts

    private var castCount: Int {
        counts.inFavor + counts.against + counts.abstained
    }

    private var requiredForQuorum: Int {
        let raw = Double(counts.totalEligible) * Double(quorumPercent) / 100.0
        return max(Int(raw.rounded(.up)), 1)
    }

    private var ringProgress: Double {
        let denom = Double(requiredForQuorum)
        guard denom > 0 else { return 0 }
        return min(Double(castCount) / denom, 1.0)
    }

    var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            QuorumRing(progress: ringProgress)
                .frame(width: 14, height: 14)

            tallyBar

            Text("\(castCount)/\(requiredForQuorum)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.secondary)
                .contentTransition(.numericText(value: Double(castCount)))
                .animation(.smooth(duration: 0.4), value: castCount)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quórum \(castCount) de \(requiredForQuorum). \(counts.inFavor) a favor, \(counts.against) en contra.")
    }

    private var tallyBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(spacing: 1.5) {
                    segment(width: geo.size.width * ratio(counts.inFavor), color: .green)
                    segment(width: geo.size.width * ratio(counts.against), color: .red)
                    segment(width: geo.size.width * ratio(counts.pending + counts.abstained), color: Color(.tertiaryLabel))
                }
                .frame(height: 4)
                .clipShape(Capsule())
                .animation(.smooth(duration: 0.5), value: counts.inFavor)
                .animation(.smooth(duration: 0.5), value: counts.against)

                // Threshold tick — 1pt vertical hairline 2pt taller than
                // the bar so it reads as the "north line" inFavor needs
                // to clear. Same semantic as VoteCountsBar's tick.
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: 8)
                    .offset(
                        x: geo.size.width * CGFloat(min(max(thresholdPercent, 0), 100)) / 100.0 - 0.5,
                        y: -2
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity)
    }

    private func ratio(_ n: Int) -> CGFloat {
        let total = max(1, counts.totalEligible)
        return CGFloat(n) / CGFloat(total)
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        color.frame(width: width)
    }
}
