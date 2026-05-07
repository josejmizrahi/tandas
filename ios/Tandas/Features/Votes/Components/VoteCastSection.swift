import SwiftUI

/// UI section compartida por todos los body components del VoteDetailView.
/// Tres estados mutuamente exclusivos:
///   - voteIsClosed: muestra resultado final (VoteResolvedView).
///   - alreadyVoted: muestra el ballot del caller (VoteAlreadyCastView).
///   - default: muestra los 3 botones in_favor / against / abstained.
///
/// Counts se renderizan abajo solo si el voto NO es anonymous, o si el
/// caller ya votó (transparencia post-cast).
struct VoteCastSection: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            stateView

            if let counts = coordinator.counts,
               !coordinator.vote.isAnonymous || coordinator.alreadyVoted {
                // VoteCountsBar takes AppealVoteCounts (legacy type from
                // pre-00020 votes). Bridge VoteCounts → AppealVoteCounts
                // inline; the two have identical shape. Audit § 5.2
                // tracks promoting VoteCountsBar to take canonical
                // VoteCounts when appeal_votes legacy is cleaned up.
                VoteCountsBar(counts: AppealVoteCounts(
                    inFavor:       counts.inFavor,
                    against:       counts.against,
                    abstained:     counts.abstained,
                    pending:       counts.pending,
                    totalEligible: counts.totalEligible
                ))
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if coordinator.voteIsClosed {
            VoteResolvedView(counts: coordinator.counts, vote: coordinator.vote)
        } else if coordinator.alreadyVoted {
            VoteAlreadyCastView(myChoice: coordinator.myCast?.choice)
        } else {
            VoteCastButtons(coordinator: coordinator)
        }
    }
}

// MARK: - Private subviews

private struct VoteCastButtons: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(spacing: RuulSpacing.s2) {
            castButton(.inFavor,    label: "A favor",      systemImage: "checkmark.circle.fill", tint: .ruulSemanticSuccess)
            castButton(.against,    label: "En contra",    systemImage: "xmark.circle.fill",     tint: .ruulSemanticError)
            castButton(.abstained,  label: "Me abstengo",  systemImage: "minus.circle.fill",     tint: .ruulTextTertiary)
        }
        .disabled(coordinator.isCasting)
        .opacity(coordinator.isCasting ? 0.5 : 1.0)
    }

    private func castButton(_ choice: VoteChoice, label: String, systemImage: String, tint: Color) -> some View {
        Button {
            Task { await coordinator.cast(choice) }
        } label: {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(label)
                    .ruulTextStyle(RuulTypography.headline)
                Spacer()
            }
            .padding(RuulSpacing.s4)
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(label)
    }
}

private struct VoteAlreadyCastView: View {
    let myChoice: VoteChoice?

    var body: some View {
        let (text, tint, icon) = display(for: myChoice)
        HStack(spacing: RuulSpacing.s2) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text("Tu voto: \(text)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    private func display(for choice: VoteChoice?) -> (String, Color, String) {
        switch choice {
        case .inFavor:    return ("a favor",     .ruulSemanticSuccess, "checkmark.circle.fill")
        case .against:    return ("en contra",   .ruulSemanticError,   "xmark.circle.fill")
        case .abstained:  return ("abstención",  .ruulTextTertiary,    "minus.circle.fill")
        case .pending, .none: return ("pendiente", .ruulTextTertiary, "clock")
        }
    }
}

private struct VoteResolvedView: View {
    let counts: VoteCounts?
    let vote: Vote

    var body: some View {
        let resolution = counts?.resolution ?? .quorumFailed
        let (label, tint) = display(for: resolution)
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(tint)
                Text("Voto \(label)")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            if let resolvedAt = vote.resolvedAt {
                Text("Cerrado \(resolvedAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    private func display(for resolution: VoteResolution) -> (String, Color) {
        switch resolution {
        case .passed:        return ("aprobado",     .ruulSemanticSuccess)
        case .failed:        return ("rechazado",    .ruulSemanticError)
        case .quorumFailed:  return ("sin quórum",   .ruulTextTertiary)
        }
    }
}
