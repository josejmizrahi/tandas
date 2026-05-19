import SwiftUI
import RuulCore
import RuulUI

/// Phase E host for fine detail. Wraps `FineDetailCoordinator` and renders
/// the fine via `UniversalResourceDetailView` + `FineBlockBuilder`. Preserves
/// the existing appeal / pay / void sheet flows from `FineDetailView` by
/// surfacing them through the block's `openDestinationId` routes and the
/// primary-action dispatch.
///
/// Call sites:
///   - `RootShellSheets+ScreenBuilders.fineDetailScreen` (full cover)
///   - `MyFinesScreenHost.fineDetailDestination` (push in nav stack)
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
                    onPrimaryAction: { Task { await dispatchPrimary() } },
                    onOpenBlock: { id in openDestination(id) },
                    onTapRelation: { _ in },
                    onSeeMoreActivity: { },
                    onOverflowAction: { _ in }
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
            rebuildBlocks()
        }
        .onChange(of: coordinator.fine) { _, _ in rebuildBlocks() }
        .onChange(of: coordinator.existingAppeal) { _, _ in rebuildBlocks() }
        // Appeal sheet
        .ruulSheet(isPresented: $appealSheetPresented) {
            AppealFineSheet(
                isPresented: $appealSheetPresented,
                fine: coordinator.fine
            ) { reason in
                Task { await coordinator.startAppeal(reason: reason) }
            }
        }
        // Void sheet
        .ruulSheet(isPresented: $voidSheetPresented) {
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
            }
        }
    }

    // MARK: - Block building

    private func rebuildBlocks() {
        let viewerCtx = BlockViewerContext(
            userId: coordinator.userId,
            permissions: [],  // FineBlockBuilder doesn't gate on permissions
            activeModules: [],
            memberId: nil
        )
        blocks = FineBlockBuilder().build(
            source: coordinator.fine,
            viewer: viewerCtx,
            now: Date()
        )
    }

    // MARK: - Dispatch

    @MainActor
    private func dispatchPrimary() async {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .payFine:
            await coordinator.payFine()
        case .castVote:
            // Appeal vote — route to appeal sheet
            appealSheetPresented = true
        case .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .openContribute, .openBooking, .viewClosed,
             .exerciseRight:
            break  // not applicable for fines
        case .none:
            break  // PrimaryAction.Kind.none — no CTA
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
