import SwiftUI
import RuulUI
import RuulCore

/// Compact metric tile shown wherever a live vote surfaces — cast picker,
/// universal resource detail, anywhere we want voters to feel quorum + time.
///
/// Surfaces the two signals a voter actually acts on: how close the vote
/// is to quorum, and how much time is left before it closes.
///
/// Apple Sports minimal — flat surface, monospaced digits, no filled
/// backgrounds. Two restrained nods to Liquid Glass:
///   - a 22pt micro quorum ring (status indicator, not a hero gauge);
///   - a red-tinted hairline stroke when fewer than 6h remain to
///     `closesAt`, so urgency is felt without shouting.
///
/// Initializer takes primitives instead of the full `Vote` model so any
/// surface (list row preview, universal detail factory, cast sheet) can
/// compose it without dragging the full model through its data flow.
struct VoteMetricsTile: View {
    /// When the vote closes. Drives the countdown + urgent stroke.
    let closesAt: Date
    /// Quorum threshold (0-100). Determines how many cast ballots are
    /// needed for the ring to fill.
    let quorumPercent: Int
    /// Members eligible to vote (denominator). 0 ⇒ ring stays empty.
    let totalEligible: Int
    /// Sum of in-favor + against + abstained (numerator). Pending
    /// ballots don't count toward quorum.
    let castCount: Int

    /// Number of ballots required to satisfy quorum given
    /// `totalEligible` and `quorumPercent`. Minimum of 1 so a 0-eligible
    /// edge case still renders sensibly.
    private var requiredForQuorum: Int {
        let raw = Double(totalEligible) * Double(quorumPercent) / 100.0
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
        let remaining = closesAt.timeIntervalSinceNow
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
            if closesAt > .now {
                Text(timerInterval: .now ... closesAt, countsDown: true)
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
        let remaining = closesAt.timeIntervalSinceNow
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
struct QuorumRing: View {
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
