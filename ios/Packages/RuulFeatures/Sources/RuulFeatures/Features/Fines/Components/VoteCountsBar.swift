import SwiftUI
import RuulUI
import RuulCore

/// Anonymized vote counts visualization for an appeal. 3 segments (a favor /
/// en contra / pendientes), proportional widths, with totals on the right.
/// Apple Sports flat — no tinted backgrounds, semantic dots only.
public struct VoteCountsBar: View {
    public let counts: VoteCounts

    public init(counts: VoteCounts) {
        self.counts = counts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: 2) {
                segment(width: ratio(counts.inFavor), color: .green)
                segment(width: ratio(counts.against), color: .red)
                segment(width: ratio(counts.pending + counts.abstained), color: Color(.tertiaryLabel))
            }
            .frame(height: 6)
            .clipShape(Capsule())
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

    private func legendItem(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: RuulSpacing.xxs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text("\(count)")
                .font(.footnote.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.primary)
        }
    }
}
