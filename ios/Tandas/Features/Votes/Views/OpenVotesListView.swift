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
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.openVotes.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh(force: true) } })
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                        .transition(.opacity)
                } else if coordinator.openVotes.isEmpty && coordinator.isLoading {
                    LoadingStateView(.list)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
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
                        LazyVStack(alignment: .leading, spacing: RuulSpacing.s5) {
                            ForEach(coordinator.sectioned(), id: \.0) { section, votes in
                                VStack(alignment: .leading, spacing: RuulSpacing.s2) {
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
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s4)
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
                }
                .accessibilityLabel("Crear votación")
            }
        }
        .task { await coordinator.refresh() }
    }

    private func voteRow(_ vote: Vote) -> some View {
        HStack(spacing: RuulSpacing.s3) {
            voteTypeIcon(vote.voteType)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ruulAccentPrimary)
                .frame(width: 32, height: 32)
                .background(Color.ruulBackgroundElevated, in: Circle())

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
        }
        .padding(RuulSpacing.s4)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
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
