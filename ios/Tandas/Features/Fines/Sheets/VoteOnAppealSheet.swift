import SwiftUI

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
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                fineCard
                appealReasonCard
                if let counts = voteCounts {
                    VoteCountsBar(counts: counts)
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
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("MULTA APELADA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                Text(fine.reason)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                Text(fine.amountFormatted)
                    .ruulTextStyle(RuulTypography.statMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
        .padding(RuulSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var appealReasonCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("ARGUMENTO DE \(appellantName.uppercased())")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(appeal.reason)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }

    private var votingButtons: some View {
        VStack(spacing: RuulSpacing.s2) {
            voteButton(
                label: "A favor — anular la multa",
                dotColor: .ruulSemanticSuccess,
                choice: .inFavor,
                primary: true
            )
            HStack(spacing: RuulSpacing.s2) {
                voteButton(
                    label: "En contra",
                    dotColor: .ruulSemanticError,
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
            HStack(spacing: RuulSpacing.s2) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(label)
                    .ruulTextStyle(RuulTypography.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.s4)
            .padding(.horizontal, RuulSpacing.s4)
            .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
            .background(primary ? Color.ruulTextPrimary : Color.ruulBackgroundElevated, in: Capsule())
            .overlay(
                primary ? nil :
                Capsule().stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }
}
