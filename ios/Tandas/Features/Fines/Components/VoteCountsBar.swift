import SwiftUI

/// Anonymized vote counts visualization for an appeal. 3 segments (a favor /
/// en contra / pendientes), proportional widths, with totals on the right.
/// Apple Sports flat — no tinted backgrounds, semantic dots only.
struct VoteCountsBar: View {
    let counts: AppealVoteCounts

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack(spacing: 2) {
                segment(width: ratio(counts.inFavor), color: .ruulSemanticSuccess)
                segment(width: ratio(counts.against), color: .ruulSemanticError)
                segment(width: ratio(counts.pending + counts.abstained), color: .ruulTextTertiary)
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: RuulSpacing.s4) {
                legendItem(color: .ruulSemanticSuccess, label: "A favor", count: counts.inFavor)
                legendItem(color: .ruulSemanticError,   label: "En contra", count: counts.against)
                Spacer()
                legendItem(color: .ruulTextTertiary,    label: "Pendiente", count: counts.pending)
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
        HStack(spacing: RuulSpacing.s1) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }
}
