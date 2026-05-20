import SwiftUI
import RuulCore
import RuulUI

/// Compact "Necesita atención" card. Renders only when
/// `context.attentionActions` is non-empty. Apple Sports alert style:
/// orange dot + bold label + summary count + chevron.
@MainActor
public struct DetailAttentionView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if !context.attentionActions.isEmpty {
            Button {
                if let first = context.attentionActions.first {
                    Task { await context.onOpenInboxAction(first) }
                }
            } label: {
                HStack(spacing: RuulSpacing.s2) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Necesita atención")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(RuulSpacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .fill(Color.orange.opacity(0.1))
                )
            }
            .buttonStyle(.ruulPress)
            .padding(.horizontal, RuulSpacing.s6)
            .symbolEffect(.bounce, value: context.attentionActions.count)
        }
    }

    private var summary: String {
        let count = context.attentionActions.count
        if count == 1, let action = context.attentionActions.first {
            return shortLabel(for: action)
        }
        return "\(count) acciones pendientes"
    }

    private func shortLabel(for action: UserAction) -> String {
        switch action.actionType {
        case .rsvpPending:            return "Confirma tu asistencia"
        case .finePending:            return "Tienes una multa pendiente"
        case .fineVoided:             return "Una multa fue anulada"
        case .fineProposalReview:     return "Revisa una propuesta de multa"
        case .appealVotePending:      return "Vota en una apelación"
        case .ruleChangeApplyPending: return "Vota un cambio de regla"
        case .votePending:            return "Vota una propuesta"
        case .hostAssigned:           return "Te asignaron como host"
        case .slotPending:            return "Tienes un turno pendiente"
        case .contributionDue:        return "Una aportación está pendiente"
        case .compensationDue:        return "Tienes una compensación pendiente"
        case .assetActionApproval:    return "Aprueba una acción de activo"
        }
    }
}
