import SwiftUI
import RuulUI
import RuulCore

/// Compact metric tile rendered above the cast picker on `VoteCastSection`.
/// Surfaces the two signals every voter needs before they act: how close
/// the vote is to quorum, and how much time is left before it closes.
///
/// Apple Sports minimal — flat surface, monospaced digits, no filled
/// backgrounds. Two restrained nods to Liquid Glass:
///   - a 22pt micro quorum ring (status indicator beside the count, not
///     a hero gauge);
///   - a red-tinted hairline stroke when fewer than 6h remain to
///     `closesAt`, so urgency is felt without shouting.
///
/// The tile renders only when the vote is OPEN. Once resolved /
/// cancelled / quorum-failed, the host's `VoteResolvedView` carries the
/// final result and a running countdown would mislead.
struct VoteMetricsTile: View {
    let vote: Vote
    let counts: VoteCounts?

    private var castCount: Int {
        guard let counts else { return 0 }
        return counts.inFavor + counts.against + counts.abstained
    }

    /// Number of ballots required to satisfy quorum given
    /// `totalEligible` and `quorumPercent`. Minimum of 1 so a 0-eligible
    /// edge case still renders sensibly (the tile would be hidden in
    /// practice but we never want a divide-by-zero in the math).
    private var requiredForQuorum: Int {
        let eligible = counts?.totalEligible ?? 0
        let raw = Double(eligible) * Double(vote.quorumPercent) / 100.0
        return max(Int(raw.rounded(.up)), 1)
    }

    /// Capped at 1.0 — once quorum is hit the ring stays full and shifts
    /// to the positive tint as a quiet celebration.
    private var ringProgress: Double {
        let denom = Double(requiredForQuorum)
        guard denom > 0 else { return 0 }
        return min(Double(castCount) / denom, 1.0)
    }

    /// True when the vote closes inside the next 6h (and isn't already
    /// closed). Drives the urgent stroke + red countdown tint.
    private var isUrgent: Bool {
        let remaining = vote.closesAt.timeIntervalSinceNow
        return remaining > 0 && remaining < 6 * 3600
    }

    var body: some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            quorumBlock
            Spacer(minLength: RuulSpacing.sm)
            countdownBlock
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(
            Color.ruulBackgroundCanvas,
            in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(
                    isUrgent ? Color.ruulNegative.opacity(0.4) : Color(.separator),
                    lineWidth: isUrgent ? 1.0 : 0.5
                )
        )
        .animation(.smooth(duration: 0.35), value: isUrgent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var quorumBlock: some View {
        HStack(spacing: RuulSpacing.xs) {
            QuorumRing(progress: ringProgress)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Quórum")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
                Text("\(castCount)/\(requiredForQuorum)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .contentTransition(.numericText(value: Double(castCount)))
                    .animation(.smooth(duration: 0.4), value: castCount)
            }
        }
    }

    @ViewBuilder
    private var countdownBlock: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("Cierra en")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.secondary)
            if vote.closesAt > .now {
                Text(timerInterval: .now ... vote.closesAt, countsDown: true)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isUrgent ? Color.ruulNegative : Color.primary)
                    .multilineTextAlignment(.trailing)
            } else {
                Text("Cerrado")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var accessibilityLabel: String {
        let quorum = "Quórum \(castCount) de \(requiredForQuorum)"
        let remaining = vote.closesAt.timeIntervalSinceNow
        if remaining <= 0 {
            return "\(quorum). Votación cerrada."
        }
        let hours = Int(remaining / 3600)
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(quorum). Cierra en \(hours) horas \(minutes) minutos."
    }
}

/// 22pt quorum ring. Stroked circle with the active arc starting at
/// 12 o'clock. Tint shifts from accent → positive once participation
/// reaches 100% of the required quorum count.
private struct QuorumRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiaryLabel).opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(progress, 0.005))
                .stroke(
                    progress >= 1.0 ? Color.ruulPositive : Color.ruulAccent,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth(duration: 0.5), value: progress)
    }
}
