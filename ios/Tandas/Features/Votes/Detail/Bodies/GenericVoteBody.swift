import SwiftUI

/// Fallback body para vote_types sin UI dedicada (V1: rule_repeal,
/// member_removal, fund_withdrawal, role_assignment, slot_dispute).
/// Renderiza title + description + payload as JSON in monospace card.
/// Cuando esos vote_types tengan feature shipped, cada uno gana su
/// body dedicado y este queda solo para `unknown` enum case.
struct GenericVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text("PAYLOAD")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(payloadJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.sm, style: .continuous))
            }
        }
    }

    private var payloadJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(coordinator.vote.payload),
              let str = String(data: data, encoding: .utf8) else {
            return "(unable to render payload)"
        }
        return str
    }
}
