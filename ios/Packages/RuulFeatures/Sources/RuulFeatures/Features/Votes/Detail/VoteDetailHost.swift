import SwiftUI
import RuulCore
import RuulUI

/// Phase E host for vote detail. Wraps `VoteDetailCoordinator` and renders
/// the vote via `UniversalResourceDetailView` + `VoteBlockBuilder`.
///
/// Doctrine §0 (universal detail v2):
///   - Primary action lives INLINE in StateHero. No sticky footer, no
///     overlay bar. The View's onPrimaryAction opens a dedicated cast
///     sheet that hosts the legacy three-choice picker.
///   - Admin/creator finalize+cancel are routed through the overflow
///     `.edit` semantic ("manage this vote") into an admin actions
///     sheet, gated by the coordinator's `shouldShowFinalize` /
///     `shouldShowCancel`.
///
/// Call site:
///   - `RootShellSheets+ScreenBuilders.voteDetailScreen` (full cover).
@MainActor
public struct VoteDetailHost: View {
    @Environment(AppState.self) private var app
    @Bindable var coordinator: VoteDetailCoordinator

    @State private var blocks: ResourceBlocks?

    /// Cast picker sheet — opens from the StateHero primary action.
    @State private var showCastSheet: Bool = false

    /// Admin actions sheet — opens from overflow `.edit` when the viewer
    /// has at least one admin/creator action available.
    @State private var showAdminSheet: Bool = false

    /// Confirmation dialogs preserved from the legacy host.
    @State private var showFinalizeConfirm: Bool = false
    @State private var showCancelConfirm: Bool = false

    public init(coordinator: VoteDetailCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if let blocks {
                UniversalResourceDetailView(
                    blocks: blocks,
                    supportedOverflowActions: supportedOverflowActions,
                    navigationTitle: coordinator.vote.title,
                    onPrimaryAction: { handlePrimaryAction() },
                    onOpenBlock: { _ in },
                    onTapRelation: { _ in },
                    onSeeMoreActivity: { /* TODO: dedicated activity history sheet */ },
                    onOverflowAction: { handleOverflow($0) }
                )
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    RuulLoadingState()
                }
            }
        }
        .task {
            await coordinator.refresh()
            await rebuildBlocks()
        }
        .onChange(of: coordinator.counts) { _, _ in Task { await rebuildBlocks() } }
        .onChange(of: coordinator.myCast) { _, _ in Task { await rebuildBlocks() } }
        .refreshable { await coordinator.refresh() }
        // Cast picker — opens from the StateHero primary action when the
        // builder emits `castVote`. The legacy VoteCastSection handles the
        // three-choice ballot inside.
        .sheet(isPresented: $showCastSheet) {
            voteCastPickerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        // Admin actions — opens from overflow `.edit` when finalize/cancel
        // is available. Closes after a successful action.
        .sheet(isPresented: $showAdminSheet) {
            voteAdminSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
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

    @MainActor
    private func rebuildBlocks() async {
        let viewerCtx = BlockViewerContext(
            userId: app.session?.user.id,    // Doctrine §F fix: real viewer id
            permissions: [],                  // VoteBlockBuilder gates on viewerHasVoted, not permissions
            activeModules: [],
            memberId: coordinator.vote.createdByMemberId
        )
        let builder = VoteBlockBuilder(viewerHasVoted: coordinator.alreadyVoted)
        let built = builder.build(source: coordinator.vote, viewer: viewerCtx, now: Date())

        // Post-build augmentation: load system_events for this vote so
        // the activity layer reflects vote_proposed / vote_cast /
        // vote_finalized / vote_cancelled events.
        let feed = await ActivityFeedLoader.load(
            app: app,
            groupId: coordinator.vote.groupId,
            resourceId: coordinator.vote.id
        )

        blocks = ResourceBlocks(
            identity: built.identity,
            state: built.state,
            properties: built.properties,
            capabilities: built.capabilities,
            relations: built.relations,
            activityHead: feed.entries,
            hasMoreActivity: feed.hasMore
        )
    }

    // MARK: - Overflow declaration

    /// Votes surface only `.edit` (gated to open the admin actions sheet
    /// when the viewer has finalize/cancel privileges). Everything else
    /// — share/calendar/wallet/archive/delete/report — doesn't apply to
    /// a governance vote and is filtered out so taps never produce a
    /// silent no-op.
    private var supportedOverflowActions: Set<UniversalResourceDetailView.OverflowAction> {
        var set: Set<UniversalResourceDetailView.OverflowAction> = []
        if coordinator.shouldShowFinalize || coordinator.shouldShowCancel {
            set.insert(.edit)
        }
        return set
    }

    // MARK: - Primary action dispatch

    /// Routes the StateHero primary action. When the builder emits
    /// `castVote`, opens the cast picker sheet; other kinds are not
    /// applicable to votes today.
    private func handlePrimaryAction() {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .castVote:
            showCastSheet = true
        case .none,
             .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .openContribute, .openBooking, .viewClosed,
             .exerciseRight, .payFine:
            break  // not applicable to votes
        }
    }

    // MARK: - Overflow

    /// Overflow menu items. `.edit` opens the admin actions sheet only
    /// when at least one admin action (finalize/cancel) is available;
    /// otherwise the tap is a no-op. Other items are not surfaced in the
    /// new view because the universal overflow is hardcoded — filtering
    /// would require host-level pruning that the doctrine doesn't expose
    /// yet (TODO: per-host overflow predicate so unsupported items
    /// disappear from the menu instead of failing silently).
    private func handleOverflow(_ action: UniversalResourceDetailView.OverflowAction) {
        switch action {
        case .edit:
            if coordinator.shouldShowFinalize || coordinator.shouldShowCancel {
                showAdminSheet = true
            }
        case .share, .addToCalendar, .walletPass, .archive, .delete, .report:
            break  // not applicable to votes
        }
    }

    // MARK: - Sheets

    /// Cast picker — wraps the legacy `VoteCastSection` in a sheet so the
    /// three-choice ballot remains intact while honoring the doctrinal
    /// "primary action lives inline + opens a dedicated picker" pattern.
    @ViewBuilder
    private var voteCastPickerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                VoteCastSection(coordinator: coordinator)
                    .padding(.horizontal, RuulSpacing.lg)
                Spacer(minLength: 0)
            }
            .padding(.top, RuulSpacing.lg)
            .navigationTitle("Tu voto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { showCastSheet = false }
                }
            }
        }
        .onChange(of: coordinator.alreadyVoted) { _, alreadyVoted in
            // Auto-dismiss once the cast goes through.
            if alreadyVoted { showCastSheet = false }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    /// Admin actions sheet — replaces the legacy bottom-bar admin row.
    /// Visible buttons are gated by the coordinator's existing predicates.
    @ViewBuilder
    private var voteAdminSheet: some View {
        NavigationStack {
            VStack(spacing: RuulSpacing.md) {
                if coordinator.shouldShowFinalize {
                    Button {
                        showAdminSheet = false
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
                        showAdminSheet = false
                        showCancelConfirm = true
                    } label: {
                        Text("Cancelar votación")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.isCancellingVote)
                }
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.lg)
            .navigationTitle("Administrar voto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { showAdminSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
