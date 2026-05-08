import SwiftUI

/// List view de votos abiertos del grupo activo. Sectiona por urgencia
/// (closing-soon vs other). Botón "+" en toolbar abre CreateVoteSheet
/// (V1: enabled solo general_proposal y rule_change).
struct OpenVotesListView: View {
    @Bindable var coordinator: OpenVotesCoordinator
    var onSelectVote: (Vote) -> Void
    var onCreateVote: () -> Void

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.openVotes.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh(force: true) } })
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.lg)
                        .transition(.opacity)
                } else if coordinator.openVotes.isEmpty && coordinator.isLoading {
                    RuulLoadingState()
                        .transition(.opacity)
                } else if coordinator.openVotes.isEmpty {
                    EmptyStateView(
                        systemImage: "hand.raised",
                        title: "No hay votos abiertos",
                        message: "Cuando el grupo abra una votación, aparecerá acá.",
                        primaryAction: ("Crear votación", onCreateVote)
                    )
                    .padding(.top, RuulSpacing.s10)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: RuulSpacing.lg) {
                            ForEach(coordinator.sectioned(), id: \.0) { section, votes in
                                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                                    Text(section.title.uppercased())
                                        .ruulTextStyle(RuulTypography.sectionLabel)
                                        .foregroundStyle(Color.ruulTextTertiary)
                                    ForEach(votes) { vote in
                                        Button { onSelectVote(vote) } label: {
                                            voteRow(vote)
                                        }
                                        .buttonStyle(.ruulPress)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.md)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh(force: true) }
                    .transition(.opacity)
                }
            }
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.openVotes.isEmpty)
        }
        .navigationTitle("Votos abiertos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCreateVote) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Crear votación")
            }
        }
        .task { await coordinator.refresh() }
    }

    private func voteRow(_ vote: Vote) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            voteTypeIcon(vote.voteType)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 32, height: 32)
                .background(Color.ruulSurface, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(vote.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                Text("Cierra \(vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func voteTypeIcon(_ type: VoteType) -> Image {
        switch type {
        case .fineAppeal:       return Image(systemName: "exclamationmark.bubble")
        case .generalProposal:  return Image(systemName: "text.bubble")
        case .ruleChange:       return Image(systemName: "list.bullet.clipboard")
        case .ruleRepeal:       return Image(systemName: "trash")
        case .memberRemoval:    return Image(systemName: "person.fill.xmark")
        case .fundWithdrawal:   return Image(systemName: "banknote")
        case .roleAssignment:   return Image(systemName: "person.badge.shield.checkmark")
        case .slotDispute:      return Image(systemName: "ticket")
        }
    }
}
