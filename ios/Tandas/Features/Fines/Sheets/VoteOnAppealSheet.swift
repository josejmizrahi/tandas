import SwiftUI
import RuulUI
import RuulCore

/// Modal where an eligible voter casts their ballot on an active appeal.
/// 3 buttons: A favor (annulla la multa), En contra (queda), Abstenerse.
/// Submitting calls `cast_appeal_vote` RPC; the trigger resolves the
/// `appealVotePending` user_action automatically.
struct VoteOnAppealSheet: View {
    @Binding var isPresented: Bool
    let fine: Fine
    let appeal: Appeal
    let appellantName: String
    let voteCounts: AppealVoteCounts?
    let onCast: (AppealVoteChoice) -> Void

    var body: some View {
        ModalSheetTemplate(
            title: "Votar apelación",
            dismissAction: { isPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                fineCard
                appealReasonCard
                if let counts = voteCounts {
                    // VoteCountsBar consume canonical VoteCounts. AppealRepository
                    // sigue devolviendo AppealVoteCounts (server-side appeal_votes
                    // legacy), así que convertimos en el call site. Cuando el
                    // V2 cleanup migre AppealRepository a VoteRepository este
                    // bridge desaparece.
                    VoteCountsBar(counts: VoteCounts(
                        inFavor:       counts.inFavor,
                        against:       counts.against,
                        abstained:     counts.abstained,
                        pending:       counts.pending,
                        totalEligible: counts.totalEligible,
                        resolution:    nil
                    ))
                }
                votingButtons
                Text("Tu voto es anónimo. Solo se publican los conteos agregados.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var fineCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("MULTA APELADA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                Text(fine.reason)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
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
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var appealReasonCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("ARGUMENTO DE \(appellantName.uppercased())")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(appeal.reason)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var votingButtons: some View {
        VStack(spacing: RuulSpacing.xs) {
            voteButton(
                label: "A favor — anular la multa",
                dotColor: .ruulPositive,
                choice: .inFavor,
                primary: true
            )
            HStack(spacing: RuulSpacing.xs) {
                voteButton(
                    label: "En contra",
                    dotColor: .ruulNegative,
                    choice: .against,
                    primary: false
                )
                voteButton(
                    label: "Abstenerme",
                    dotColor: .ruulTextTertiary,
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
                    .ruulTextStyle(RuulTypography.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.md)
            .padding(.horizontal, RuulSpacing.md)
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
            .background(primary ? Color.ruulTextPrimary : Color.ruulSurface, in: Capsule())
            .overlay(
                primary ? nil :
                Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
