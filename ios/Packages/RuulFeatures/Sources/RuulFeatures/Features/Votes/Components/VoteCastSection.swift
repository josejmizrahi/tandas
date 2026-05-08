import SwiftUI
import RuulUI
import RuulCore

/// UI section compartida por todos los body components del VoteDetailView.
/// Tres estados mutuamente exclusivos:
///   - voteIsClosed: muestra resultado final (VoteResolvedView).
///   - alreadyVoted: muestra el ballot del caller (VoteAlreadyCastView).
///   - default: muestra los 3 botones in_favor / against / abstained.
///
/// Counts se renderizan abajo solo si el voto NO es anonymous, o si el
/// caller ya votó (transparencia post-cast).
public struct VoteCastSection: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
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

    public var body: some View {
        VStack(spacing: RuulSpacing.xs) {
            castButton(.inFavor,    label: "A favor",      systemImage: "checkmark.circle.fill", tint: .ruulPositive)
            castButton(.against,    label: "En contra",    systemImage: "xmark.circle.fill",     tint: .ruulNegative)
            castButton(.abstained,  label: "Me abstengo",  systemImage: "minus.circle.fill",     tint: .ruulTextTertiary)
        }
        .disabled(coordinator.isCasting)
        .opacity(coordinator.isCasting ? RuulOpacity.disabled : 1.0)
    }

    private func castButton(_ choice: VoteChoice, label: String, systemImage: String, tint: Color) -> some View {
        Button {
            Task { await coordinator.cast(choice) }
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.headline)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(label)
    }
}

private struct VoteAlreadyCastView: View {
    public let myChoice: VoteChoice?

    public var body: some View {
        let (text, tint, icon) = display(for: myChoice)
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text("Tu voto: \(text)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
    }

    private func display(for choice: VoteChoice?) -> (String, Color, String) {
        switch choice {
        case .inFavor:    return ("a favor",     .ruulPositive, "checkmark.circle.fill")
        case .against:    return ("en contra",   .ruulNegative,   "xmark.circle.fill")
        case .abstained:  return ("abstención",  .ruulTextTertiary,    "minus.circle.fill")
        case .pending, .none: return ("pendiente", .ruulTextTertiary, "clock")
        }
    }
}

private struct VoteResolvedView: View {
    public let counts: VoteCounts?
    public let vote: Vote

    public var body: some View {
        let displayed = display()
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(displayed.tint)
                    .accessibilityHidden(true)
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
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
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
            case .passed:        return Displayed(label: "Voto aprobado",    tint: .ruulPositive)
            case .failed:        return Displayed(label: "Voto rechazado",   tint: .ruulNegative)
            case .quorumFailed:  return Displayed(label: "Voto sin quórum",  tint: .ruulTextTertiary)
            case nil:            return Displayed(label: "Voto cerrado",     tint: .ruulTextTertiary)  // resolver pending
            }
        }
    }
}
