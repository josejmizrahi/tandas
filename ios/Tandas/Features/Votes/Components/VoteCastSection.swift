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
                VoteCountsBar(counts: counts)
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
        .opacity(coordinator.isCasting ? RuulOpacity.disabled : 1.0)
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
        let displayed = display()
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(displayed.tint)
                Text(displayed.label)
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

    private struct Displayed {
        let label: String
        let tint: Color
    }

    /// Vote status is the canonical source of truth. counts.resolution is
    /// a denormalized convenience but may be nil during refresh-in-flight.
    /// Switch on status first; fall back to counts.resolution only when
    /// status is .resolved (positive resolution required, success or fail).
    private func display() -> Displayed {
        switch vote.status {
        case .quorumFailed:
            return Displayed(label: "Voto sin quórum", tint: .ruulTextTertiary)
        case .cancelled:
            return Displayed(label: "Voto cancelado",  tint: .ruulTextTertiary)
        case .open:
            // voteIsClosed should have prevented us reaching this branch,
            // but defensively render a neutral state.
            return Displayed(label: "Voto cerrado",    tint: .ruulTextTertiary)
        case .closed, .resolved:
            switch counts?.resolution {
            case .passed:        return Displayed(label: "Voto aprobado",    tint: .ruulSemanticSuccess)
            case .failed:        return Displayed(label: "Voto rechazado",   tint: .ruulSemanticError)
            case .quorumFailed:  return Displayed(label: "Voto sin quórum",  tint: .ruulTextTertiary)
            case nil:            return Displayed(label: "Voto cerrado",     tint: .ruulTextTertiary)  // resolver pending
            }
        }
    }
}
