import SwiftUI
import RuulCore
import RuulUI

/// Phase E host for vote detail. Wraps `VoteDetailCoordinator` and renders
/// the vote via `UniversalResourceDetailView` + `VoteBlockBuilder`. The
/// `VoteCastSection` is embedded as an overlay beneath the block scroll
/// so the three voting buttons remain accessible while the block tree
/// provides identity, state, and tally context above.
///
/// Call site:
///   - `RootShellSheets+ScreenBuilders.voteDetailScreen` (full cover).
@MainActor
public struct VoteDetailHost: View {
    @Bindable var coordinator: VoteDetailCoordinator

    @State private var blocks: ResourceBlocks?
    @State private var showFinalizeConfirm = false
    @State private var showCancelConfirm = false

    public init(coordinator: VoteDetailCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if let blocks {
                ZStack(alignment: .bottom) {
                    UniversalResourceDetailView(
                        blocks: blocks,
                        onPrimaryAction: { /* cast section handles voting */ },
                        onOpenBlock: { _ in },
                        onTapRelation: { _ in },
                        onSeeMoreActivity: { },
                        onOverflowAction: { handleOverflow($0) }
                    )
                    // Preserve vote-cast UX below the block tree
                    VStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: RuulSpacing.sm) {
                            VoteCastSection(coordinator: coordinator)
                            adminActionsSection
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.vertical, RuulSpacing.sm)
                        .ruulGlass(Rectangle(), material: .regular)
                    }
                    .allowsHitTesting(footerHasContent)
                }
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    RuulLoadingState()
                }
            }
        }
        .task {
            await coordinator.refresh()
            rebuildBlocks()
        }
        .onChange(of: coordinator.counts) { _, _ in rebuildBlocks() }
        .onChange(of: coordinator.myCast) { _, _ in rebuildBlocks() }
        .refreshable { await coordinator.refresh() }
        .alert("Finalizar votación", isPresented: $showFinalizeConfirm) {
            Button("Finalizar", role: .destructive) {
                Task { await coordinator.finalizeManually() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("¿Finalizar este voto ahora? Se calculará el resultado con los votos actuales.")
        }
        .alert("Cancelar votación", isPresented: $showCancelConfirm) {
            Button("Cancelar votación", role: .destructive) {
                Task { await coordinator.cancelVote() }
            }
            Button("No cancelar", role: .cancel) {}
        } message: {
            Text("¿Cancelar este voto? Solo puedes cancelar si nadie ha votado aún.")
        }
    }

    // MARK: - Block building

    private func rebuildBlocks() {
        let viewerCtx = BlockViewerContext(
            userId: nil,
            permissions: [],
            activeModules: [],
            memberId: coordinator.vote.createdByMemberId
        )
        let builder = VoteBlockBuilder(viewerHasVoted: coordinator.alreadyVoted)
        blocks = builder.build(source: coordinator.vote, viewer: viewerCtx, now: Date())
    }

    // MARK: - Admin section

    @ViewBuilder
    private var adminActionsSection: some View {
        if coordinator.shouldShowFinalize {
            Button {
                showFinalizeConfirm = true
            } label: {
                HStack {
                    if coordinator.isFinalizingManually {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text("Finalizar votación")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ruulAccent)
            .disabled(coordinator.isFinalizingManually)
        }
        if coordinator.shouldShowCancel {
            Button(role: .destructive) {
                showCancelConfirm = true
            } label: {
                Text("Cancelar votación")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isCancellingVote)
        }
    }

    private var footerHasContent: Bool {
        !coordinator.voteIsClosed || coordinator.shouldShowFinalize || coordinator.shouldShowCancel
    }

    // MARK: - Overflow

    private func handleOverflow(_ action: UniversalResourceDetailView.OverflowAction) {
        // Votes don't surface overflow actions in Phase E
    }
}
