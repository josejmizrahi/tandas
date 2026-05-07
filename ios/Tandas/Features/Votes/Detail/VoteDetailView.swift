import SwiftUI

/// Container del detail screen de un Vote. Header (title + meta) +
/// body type-specific (router por vote.voteType) + cast section
/// compartida.
///
/// Bodies son views privadas en archivos separados bajo Detail/Bodies/.
/// Cuando llega un nuevo vote_type, agregar su body file y un case
/// nuevo al switch.
struct VoteDetailView: View {
    @Bindable var coordinator: VoteDetailCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                VoteHeader(vote: coordinator.vote)
                bodyForType
                VoteCastSection(coordinator: coordinator)
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.top, RuulSpacing.s2)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
        .task { await coordinator.refresh() }
        .refreshable { await coordinator.refresh() }
    }

    @ViewBuilder
    private var bodyForType: some View {
        switch coordinator.vote.voteType {
        case .fineAppeal:        FineAppealVoteBody(coordinator: coordinator)
        case .generalProposal:   GeneralProposalVoteBody(coordinator: coordinator)
        case .ruleChange:        RuleChangeVoteBody(coordinator: coordinator)
        case .ruleRepeal,
             .memberRemoval,
             .fundWithdrawal,
             .roleAssignment,
             .slotDispute:       GenericVoteBody(coordinator: coordinator)
        }
    }
}

// MARK: - Private subview

private struct VoteHeader: View {
    let vote: Vote

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(typeLabel.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulAccentPrimary)
            Text(vote.title)
                .ruulTextStyle(RuulTypography.titleLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, RuulSpacing.s4)
    }

    private var typeLabel: String {
        switch vote.voteType {
        case .fineAppeal:       return "Apelación de multa"
        case .generalProposal:  return "Propuesta"
        case .ruleChange:       return "Cambio de regla"
        case .ruleRepeal:       return "Archivar regla"
        case .memberRemoval:    return "Remover miembro"
        case .fundWithdrawal:   return "Retirar fondos"
        case .roleAssignment:   return "Asignar rol"
        case .slotDispute:      return "Disputa de slot"
        }
    }
}
