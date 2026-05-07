import SwiftUI

/// Body para `VoteType.ruleChange`. Lee `vote.payload` con shape
/// `{ "current_amount": int, "proposed_amount": int }` y renderiza
/// un diff visual (current → proposed) más la razón propuesta.
///
/// El rule_id está en `vote.referenceId`. V1 no fetcha el rule del
/// repo aquí — la regla puede haber sido archivada mid-vote. El body
/// proyecta el snapshot del momento del vote (los amounts en payload).
struct RuleChangeVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    private var currentAmount: Int? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .int(let v) = obj["current_amount"] else { return nil }
        return v
    }

    private var proposedAmount: Int? {
        guard case .object(let obj) = coordinator.vote.payload,
              case .int(let v) = obj["proposed_amount"] else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s5) {
            // Razón del cambio (description del vote).
            if let desc = coordinator.vote.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                    Text("RAZÓN")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(desc)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Diff visual.
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("CAMBIO PROPUESTO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                HStack(spacing: RuulSpacing.s4) {
                    amountChip(label: "Actual",  value: currentAmount,  tint: Color.ruulTextTertiary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Color.ruulTextTertiary)
                    amountChip(label: "Nuevo",   value: proposedAmount, tint: Color.ruulSemanticSuccess)
                }
            }

            HStack(spacing: RuulSpacing.s2) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
        }
    }

    private func amountChip(label: String, value: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(value.map { "$\($0)" } ?? "—")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(tint)
        }
        .padding(RuulSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.sm, style: .continuous))
    }
}
