import SwiftUI
import RuulUI
import RuulCore

/// Body para `VoteType.ruleChange`. Lee `vote.payload` con shape
/// `{ "current_amount": int, "proposed_amount": int }` y renderiza
/// un diff visual (current → proposed) más la razón propuesta.
///
/// El rule_id está en `vote.referenceId`. V1 no fetcha el rule del
/// repo aquí — la regla puede haber sido archivada mid-vote. El body
/// proyecta el snapshot del momento del vote (los amounts en payload).
public struct RuleChangeVoteBody: View {
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

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            // Razón del cambio (description del vote).
            if let desc = coordinator.vote.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text("RAZÓN")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Diff visual.
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text("CAMBIO PROPUESTO")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                HStack(spacing: RuulSpacing.md) {
                    amountChip(label: "Actual",  value: currentAmount,  tint: Color(.tertiaryLabel))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Color(.tertiaryLabel))
                        .accessibilityHidden(true)
                    amountChip(label: "Nuevo",   value: proposedAmount, tint: Color.green)
                }
            }

            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock")
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
        }
    }

    private func amountChip(label: String, value: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text(value.map { "$\($0)" } ?? "—")
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(RuulSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.small, style: .continuous))
    }
}
