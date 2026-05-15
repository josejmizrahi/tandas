import SwiftUI
import RuulUI
import RuulCore

/// List view de votos abiertos del grupo activo. Sectiona por urgencia
/// (closing-soon vs other). Botón "+" en toolbar abre CreateVoteSheet
/// (V1: enabled solo general_proposal y rule_change).
public struct OpenVotesListView: View {
    @Bindable var coordinator: OpenVotesCoordinator
    public var onSelectVote: (Vote) -> Void
    public var onCreateVote: () -> Void

    public init(coordinator: OpenVotesCoordinator, onSelectVote: @escaping (Vote) -> Void, onCreateVote: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onSelectVote = onSelectVote
        self.onCreateVote = onCreateVote
    }

    public var body: some View {
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
                    // Beta 1 W4 F-4.3: hide the "Crear votación" CTA
                    // while generic vote creation is gated. Appeal-driven
                    // votes still open from the fine flow.
                    EmptyStateView(
                        systemImage: "hand.raised",
                        title: "No hay votos abiertos",
                        message: "Cuando el grupo abra una votación, aparecerá acá.",
                        primaryAction: BetaFeatureFlags.current.showGenericVoteCreation
                            ? ("Crear votación", onCreateVote) : nil
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
            // Beta 1 W4 F-4.3: gate the toolbar "+" too. With the
            // CTA hidden in both places, beta users can only land on
            // an appeal-driven vote (opened from the fines flow).
            if BetaFeatureFlags.current.showGenericVoteCreation {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreateVote) {
                        Image(systemName: "plus")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Crear votación")
                }
            }
        }
        .task { await coordinator.refresh() }
    }

    private func voteRow(_ vote: Vote) -> some View {
        let alreadyCast = coordinator.hasCast(vote.id)
        return HStack(spacing: RuulSpacing.sm) {
            voteTypeIcon(vote.voteType)
                .ruulTextStyle(RuulTypography.headlineMedium)
                .foregroundStyle(alreadyCast ? Color.ruulTextTertiary : Color.ruulAccent)
                .frame(width: 32, height: 32)
                .background(Color.ruulSurface, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(vote.title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                HStack(spacing: RuulSpacing.xs) {
                    if alreadyCast {
                        Image(systemName: "checkmark.circle.fill")
                            .ruulTextStyle(RuulTypography.microSemibold)
                            .foregroundStyle(Color.ruulPositive)
                            .accessibilityHidden(true)
                        Text("Ya votaste")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Text("·")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Text("Cierra \(vote.closesAt.ruulRelativeDescription)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
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
        case .ledgerReview:     return Image(systemName: "dollarsign.circle")
        }
    }
}
