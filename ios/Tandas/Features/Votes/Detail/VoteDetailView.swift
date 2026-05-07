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
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                VoteHeader(vote: coordinator.vote)
                SwiftUI.Group {
                    if let error = coordinator.error, coordinator.counts == nil {
                        ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                            .transition(.opacity)
                    } else {
                        bodyForType
                        VoteCastSection(coordinator: coordinator)
                    }
                }
                .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackground.ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(typeLabel.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulAccent)
            Text(vote.title)
                .ruulTextStyle(RuulTypography.titleLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, RuulSpacing.md)
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
