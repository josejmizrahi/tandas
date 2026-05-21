import SwiftUI
import RuulCore
import RuulUI

/// Phase E host for fine detail. Wraps `FineDetailCoordinator` and renders
/// the fine via `UniversalResourceDetailView` + `FineBlockBuilder`.
///
/// Doctrine §0 + Addendum F:
///   - Primary action (`.payFine`) lives inline in StateHero; we route
///     it to `FineRepository.payFine` → `rpc('pay_fine')`.
///   - The legacy void-fine surface (admin-only, destructive) is
///     surfaced through the overflow `.delete` slot ("Anular multa")
///     when `canVoidFine` is true, gated by the governance service.
///   - Appeal lifecycle: the `appeal` capability block emits
///     `openDestinationId = "appeal.vote"`. Tapping pushes the appeal's
///     vote screen via `onViewAppeal`.
///   - Activity feed loaded via the shared `ActivityFeedLoader` so the
///     fine's `fine_proposed` / `fine_paid` / `fine_appealed` /
///     `fine_voided` system_events surface inline at the bottom.
@MainActor
public struct FineDetailHost: View {
    @Environment(AppState.self) private var app
    @Bindable var coordinator: FineDetailCoordinator

    public var onViewAppeal: ((Appeal) -> Void)?

    @State private var blocks: ResourceBlocks?
    @State private var appealSheetPresented = false
    @State private var voidSheetPresented = false
    @State private var canVoidFine: Bool = false

    public init(
        coordinator: FineDetailCoordinator,
        onViewAppeal: ((Appeal) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onViewAppeal = onViewAppeal
    }

    public var body: some View {
        Group {
            if let blocks {
                UniversalResourceDetailView(
                    blocks: blocks,
                    supportedOverflowActions: supportedOverflowActions,
                    navigationTitle: coordinator.fine.reason,
                    onPrimaryAction: { Task { await dispatchPrimary() } },
                    onOpenBlock: { id in openDestination(id) },
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
            await coordinator.trackSeen()
            canVoidFine = await computeCanVoid()
            await rebuildBlocks()
        }
        .onChange(of: coordinator.fine) { _, _ in
            Task { await rebuildBlocks() }
        }
        .onChange(of: coordinator.existingAppeal) { _, _ in
            Task { await rebuildBlocks() }
        }
        // Appeal sheet — opened from primary action when builder emits
        // an appeal-cast intent (no current path; reserved for future
        // builder rewrite that surfaces "Apelar" as a primary action).
        .sheet(isPresented: $appealSheetPresented) {
            AppealFineSheet(
                isPresented: $appealSheetPresented,
                fine: coordinator.fine
            ) { reason in
                Task { await coordinator.startAppeal(reason: reason) }
            }
            .presentationDetents([.medium])
            .presentationBackground(.regularMaterial)
        }
        // Void fine sheet — admin destructive action surfaced through
        // the overflow `.delete` slot.
        .sheet(isPresented: $voidSheetPresented) {
            if canVoidFine {
                VoidFineSheet(
                    isPresented: $voidSheetPresented,
                    coordinator: VoidFineCoordinator(
                        fine: coordinator.fine,
                        fineRepo: app.fineRepo,
                        groupsRepo: app.groupsRepo,
                        onSubmitted: { @MainActor in
                            await coordinator.refresh()
                        }
                    )
                )
                .presentationDetents([.medium])
                .presentationBackground(.regularMaterial)
            }
        }
    }

    // MARK: - Block building

    @MainActor
    private func rebuildBlocks() async {
        let viewerCtx = BlockViewerContext(
            userId: coordinator.userId,
            permissions: [],  // FineBlockBuilder gates only on debtor identity
            activeModules: [],
            memberId: nil
        )
        let built = FineBlockBuilder().build(
            source: coordinator.fine,
            viewer: viewerCtx,
            now: Date()
        )

        // Post-build augmentation: load system_events for this fine so the
        // activity layer reflects the real audit trail (proposed, paid,
        // appealed, voided).
        let feed = await ActivityFeedLoader.load(
            app: app,
            groupId: coordinator.fine.groupId,
            resourceId: coordinator.fine.id
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

    // MARK: - Dispatch

    @MainActor
    private func dispatchPrimary() async {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .payFine:
            await coordinator.payFine()
        case .none,
             .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .openContribute, .openBooking, .viewClosed,
             .exerciseRight, .castVote:
            break  // not applicable to fines (castVote is for votes only)
        }
    }

    private func openDestination(_ id: String) {
        switch id {
        case "appeal.vote":
            if let appeal = coordinator.existingAppeal {
                onViewAppeal?(appeal)
            }
        default:
            break
        }
    }

    // MARK: - Overflow

    /// Fines surface only the destructive admin lane through the overflow
    /// (admin "Anular multa") and Share. Other meta-actions
    /// (edit / calendar / wallet) don't apply to a fine record.
    private var supportedOverflowActions: Set<UniversalResourceDetailView.OverflowAction> {
        var set: Set<UniversalResourceDetailView.OverflowAction> = [.share]
        if canVoidFine { set.insert(.delete) }   // "Eliminar" label = "void" semantically
        return set
    }

    private func handleOverflow(_ action: UniversalResourceDetailView.OverflowAction) {
        switch action {
        case .share:
            // Phase F follow-up: deep-link share of the fine
            break
        case .delete:
            // .delete is the admin "Anular multa" lane. The label inside
            // the menu still reads "Eliminar" — semantically equivalent
            // for a fine (the row stays in audit but is voided).
            if canVoidFine { voidSheetPresented = true }
        case .edit, .archive, .addToCalendar, .walletPass, .report:
            break  // filtered out by supportedOverflowActions
        }
    }

    // MARK: - Governance gate

    @MainActor
    private func computeCanVoid() async -> Bool {
        guard let group = app.groups.first(where: { $0.id == coordinator.fine.groupId }),
              let rows = try? await app.groupsRepo.membersWithProfiles(of: coordinator.fine.groupId),
              let member = rows.first(where: { $0.member.userId == coordinator.userId })?.member,
              let decision = try? await app.governance.canPerform(
                  .voidFine, member: member, in: group, context: nil
              )
        else { return false }
        if case .allowed = decision { return true }
        return false
    }
}
