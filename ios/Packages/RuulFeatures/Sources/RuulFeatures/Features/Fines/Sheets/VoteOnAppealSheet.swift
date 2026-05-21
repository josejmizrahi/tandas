import SwiftUI
import RuulUI
import RuulCore

/// Modal where an eligible voter casts their ballot on an active appeal.
/// 3 buttons: A favor (annulla la multa), En contra (queda), Abstenerse.
/// Submitting calls `cast_appeal_vote` RPC; the trigger resolves the
/// `appealVotePending` user_action automatically.
public struct VoteOnAppealSheet: View {
    @Binding var isPresented: Bool
    public let fine: Fine
    public let appeal: Appeal
    public let appellantName: String
    public let voteCounts: AppealVoteCounts?
    public let onCast: (AppealVoteChoice) -> Void

    public init(isPresented: Binding<Bool>, fine: Fine, appeal: Appeal, appellantName: String, voteCounts: AppealVoteCounts?, onCast: @escaping (AppealVoteChoice) -> Void) {
        self._isPresented = isPresented
        self.fine = fine
        self.appeal = appeal
        self.appellantName = appellantName
        self.voteCounts = voteCounts
        self.onCast = onCast
    }

    public var body: some View {
        ModalSheetTemplate(
            title: "Votar apelación",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                fineCard
                appealReasonCard
                if let counts = voteCounts {
                    // AppealRepository devuelve AppealVoteCounts por compat con el
                    // protocol; el wire-shape ya es el genérico vote_casts (post-00047).
                    // Conversión local hasta que el AppealRepository protocol se
                    // colapse en VoteRepository (V2 follow-up — todavía no priorizado).
                    VoteCountsBar(counts: VoteCounts(
                        inFavor:       counts.inFavor,
                        against:       counts.against,
                        abstained:     counts.abstained,
                        pending:       counts.pending,
                        totalEligible: counts.totalEligible,
                        resolution:    nil
                    ))
                    thresholdFootnote(counts: counts)
                } else {
                    thresholdFootnote(counts: nil)
                }
                votingButtons
                Text("Tu voto es anónimo. Solo se publican los conteos agregados.")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var fineCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("MULTA APELADA")
            HStack {
                Text(fine.reason)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer()
                RuulMoneyView(
                    amount: fine.amount,
                    currency: "MXN",
                    size: .medium,
                    color: .neutral
                )
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var appealReasonCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            RuulListSectionHeader("ARGUMENTO DE \(appellantName.uppercased())")
            Text(appeal.reason)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    /// P1 — UXJourney: "no muestra cuántos miembros votarán ni el
    /// threshold". El usuario antes votaba sin entender qué hace falta
    /// para anular. Ahora muestra una línea con la regla.
    /// Si tenemos counts (server populated), uses el totalEligible
    /// real; si no, copy genérico al estilo template default (50% a
    /// favor de los que voten para anular).
    @ViewBuilder
    private func thresholdFootnote(counts: AppealVoteCounts?) -> some View {
        let copy: String = {
            if let counts {
                let needed = max(1, Int(ceil(Double(counts.totalEligible) * 0.5)) + 1)
                return "Necesitan \(needed) de \(counts.totalEligible) miembros votar a favor para anular la multa."
            }
            return "La multa se anula si la mayoría del grupo vota a favor."
        }()
        Text(copy)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var votingButtons: some View {
        VStack(spacing: RuulSpacing.xs) {
            voteButton(
                label: "A favor — anular la multa",
                dotColor: .green,
                choice: .inFavor,
                primary: true
            )
            HStack(spacing: RuulSpacing.xs) {
                voteButton(
                    label: "En contra",
                    dotColor: .red,
                    choice: .against,
                    primary: false
                )
                voteButton(
                    label: "Abstenerme",
                    dotColor: Color(.tertiaryLabel),
                    choice: .abstained,
                    primary: false
                )
            }
        }
    }

    private func voteButton(label: String, dotColor: Color, choice: AppealVoteChoice, primary: Bool) -> some View {
        Button {
            onCast(choice)
            isPresented = false
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(label)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.md)
            .padding(.horizontal, RuulSpacing.md)
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.primary)
            .background(primary ? Color.primary : Color.ruulSurface, in: Capsule())
            .overlay(
                primary ? nil :
                Capsule().stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
