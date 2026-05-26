import SwiftUI
import RuulUI
import RuulCore

/// UI section shared by every vote body. Three mutually exclusive states:
///   - `voteIsClosed` → final result (`VoteResolvedView`).
///   - `alreadyVoted` → the viewer's ballot (`VoteAlreadyCastView`).
///   - default       → the three-choice cast buttons.
///
/// V2 (2026-05-24, Option B redesign): adds a `VoteMetricsTile` above the
/// ballot when the vote is open — micro quorum ring + live countdown,
/// urgent stroke under 6h. Counts bar gains a threshold tick so the
/// voter sees where "in favor" needs to land to pass. Cast buttons
/// adopt the iOS 26 `.glass` button style + selection haptic so the
/// act of casting feels material, not procedural.
///
/// Counts render below only when the vote is NOT anonymous, or the
/// caller has already cast — same transparency contract as before.
public struct VoteCastSection: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            if !coordinator.voteIsClosed {
                VoteMetricsTile(
                    closesAt: coordinator.vote.closesAt,
                    quorumPercent: coordinator.vote.quorumPercent,
                    totalEligible: coordinator.counts?.totalEligible ?? 0,
                    castCount: castCount(coordinator.counts)
                )
            }

            stateView

            if let counts = coordinator.counts,
               !coordinator.vote.isAnonymous || coordinator.alreadyVoted {
                VoteCountsBar(
                    counts: counts,
                    thresholdPercent: coordinator.voteIsClosed ? nil : coordinator.vote.thresholdPercent
                )
            }
        }
        // FASE 3 D.1: voto exitoso → .success haptic. Mantiene el
        // modifier en el outer container así sigue vivo durante la
        // transición VoteCastButtons → VoteAlreadyCastView.
        .sensoryFeedback(.success, trigger: coordinator.alreadyVoted)
    }

    private func castCount(_ counts: VoteCounts?) -> Int {
        guard let counts else { return 0 }
        return counts.inFavor + counts.against + counts.abstained
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
    /// FASE 3 B.1 (pure morph): tracks which pill was tapped so SOLO ese
    /// botón muestra ProgressView + label morph durante el cast. Reemplaza
    /// el patrón banned `.disabled + .opacity(0.5)` en el grupo entero.
    @State private var castingChoice: VoteChoice?

    public var body: some View {
        VStack(spacing: RuulSpacing.xs) {
            castButton(.inFavor,    label: "A favor",      systemImage: "checkmark.circle.fill", tint: .green)
            castButton(.against,    label: "En contra",    systemImage: "xmark.circle.fill",     tint: .red)
            castButton(.abstained,  label: "Me abstengo",  systemImage: "minus.circle.fill",     tint: Color(.tertiaryLabel))
        }
        .sensoryFeedback(.selection, trigger: castingChoice)
    }

    private func castButton(_ choice: VoteChoice, label: String, systemImage: String, tint: Color) -> some View {
        let isMine = castingChoice == choice && coordinator.isCasting
        return Button {
            castingChoice = choice
            Task { await coordinator.cast(choice) }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                if isMine {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(isMine ? "Votando…" : label)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .contentTransition(.opacity)
                Spacer()
                if !isMine {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .animation(.snappy(duration: 0.18), value: isMine)
        }
        .buttonStyle(.glass)
        .disabled(coordinator.isCasting)
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
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }

    private func display(for choice: VoteChoice?) -> (String, Color, String) {
        switch choice {
        case .inFavor:    return ("a favor",     .green, "checkmark.circle.fill")
        case .against:    return ("en contra",   .red,   "xmark.circle.fill")
        case .abstained:  return ("abstención",  Color(.tertiaryLabel),    "minus.circle.fill")
        case .pending, .none: return ("pendiente", Color(.tertiaryLabel), "clock")
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
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
            if let resolvedAt = vote.resolvedAt {
                Text("Cerrado \(resolvedAt.ruulRelativeDescription)")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
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
            return Displayed(label: "Voto sin quórum", tint: Color(.tertiaryLabel))
        case .cancelled:
            return Displayed(label: "Voto cancelado",  tint: Color(.tertiaryLabel))
        case .open:
            // voteIsClosed should have prevented us reaching this branch,
            // but defensively render a neutral state.
            return Displayed(label: "Voto cerrado",    tint: Color(.tertiaryLabel))
        case .closed, .resolved:
            switch counts?.resolution {
            case .passed:        return Displayed(label: "Voto aprobado",    tint: .green)
            case .failed:        return Displayed(label: "Voto rechazado",   tint: .red)
            case .quorumFailed:  return Displayed(label: "Voto sin quórum",  tint: Color(.tertiaryLabel))
            case nil:            return Displayed(label: "Voto cerrado",     tint: Color(.tertiaryLabel))  // resolver pending
            }
        }
    }
}
