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
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: VoteDetailCoordinator

    @State private var blocks: ResourceBlocks?

    /// Group member directory keyed by `group_members.id`. Loaded once on
    /// appear so we can resolve `vote.createdByMemberId` → display name
    /// for the `GroupContextSlot` "Propuesto por" line. Falls back to
    /// "Miembro" when the directory hasn't landed yet.
    @State private var membersByMemberId: [UUID: MemberWithProfile] = [:]

    /// Cast picker sheet — opens from the StateHero primary action.
    @State private var showCastSheet: Bool = false

    /// Admin actions sheet — opens from overflow `.edit` when the viewer
    /// has at least one admin/creator action available.
    @State private var showAdminSheet: Bool = false

    /// Confirmation dialogs preserved from the legacy host.
    @State private var showFinalizeConfirm: Bool = false
    @State private var showCancelConfirm: Bool = false
    /// "Ver más" tap on the Activity layer.
    @State private var activityHistoryPresented: Bool = false

    public init(coordinator: VoteDetailCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if let blocks {
                ResourceDetailContent(config: makeConfig(blocks: blocks))
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await coordinator.refresh()
            await loadMembers()
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
                .presentationBackground(.ultraThinMaterial)
        }
        // Admin actions — opens from overflow `.edit` when finalize/cancel
        // is available. Closes after a successful action.
        .sheet(isPresented: $showAdminSheet) {
            voteAdminSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
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
        .sheet(isPresented: $activityHistoryPresented) {
            ResourceActivityHistorySheet(
                groupId: coordinator.vote.groupId,
                resourceId: coordinator.vote.id,
                displayName: coordinator.vote.title
            )
            .environment(app)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.visible)
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

    // MARK: - ResourceBlocks → ResourceConfig

    /// Resolves the viewer's own ballot into a `ViewerVote` so the
    /// factory can render a presence row. RLS hides every other
    /// member's cast, so this is the honest minimum visible-people
    /// surface (PR #6 of Doctrine v2 backlog). Returns nil when the
    /// viewer hasn't cast yet (cell stays hidden until they vote).
    private func viewerVoteForFactory() -> VoteInput.ViewerVote? {
        guard let cast = coordinator.myCast, cast.choice != .pending else {
            return nil
        }
        let name = app.profile?.displayName ?? "Tú"
        let avatarURL: URL? = app.profile?.avatarUrl.flatMap(URL.init(string:))
        return VoteInput.ViewerVote(
            choice: cast.choice,
            castAt: cast.castAt,
            viewerName: name,
            viewerAvatarURL: avatarURL
        )
    }

    /// Builds the `VoteInput` the new `.vote(_:)` factory expects from
    /// the live coordinator state. Renders the tally section + decision
    /// rules + inline cast action with the legacy admin finalize/cancel
    /// in the toolbar menu.
    private func makeConfig(blocks: ResourceBlocks) -> ResourceConfig {
        let v = coordinator.vote
        let counts = coordinator.counts
        let input = VoteInput(
            id: v.id.uuidString,
            title: v.title,
            description: v.description,
            statusLabel: Self.statusLabel(for: v, counts: counts),
            voteTypeLabel: Self.voteTypeLabel(v.voteType),
            timingLabel: Self.timingLabel(for: v),
            closesAt: v.closesAt,
            isOpen: v.status == .open,
            inFavor:    counts?.inFavor ?? 0,
            against:    counts?.against ?? 0,
            abstained:  counts?.abstained ?? 0,
            pending:    counts?.pending ?? 0,
            totalEligible: counts?.totalEligible ?? 0,
            quorumPercent:    v.quorumPercent,
            thresholdPercent: v.thresholdPercent,
            viewerAlreadyVoted: coordinator.alreadyVoted,
            viewerVote: viewerVoteForFactory(),
            activity: blocks.activityHead.map(Self.mapActivityEntry)
        )
        var toolbar: [ToolbarMenuItem] = []
        if coordinator.shouldShowFinalize {
            toolbar.append(ToolbarMenuItem(label: "Finalizar votación", icon: "checkmark.seal") {
                showFinalizeConfirm = true
            })
        }
        if coordinator.shouldShowCancel {
            toolbar.append(ToolbarMenuItem(label: "Cancelar votación", icon: "xmark.circle", role: .destructive) {
                showCancelConfirm = true
            })
        }
        return withGroupContext(.vote(
            input,
            onCast: { showCastSheet = true },
            toolbarMenu: toolbar
        ))
    }

    /// Splices the parent `Group` into the config so `GroupContextSlot`
    /// renders the persistent group header + "Propuesto por {name}"
    /// resolved through `membersByMemberId`. Falls back to nil when the
    /// directory hasn't loaded or the proposer member row was deleted.
    private func withGroupContext(_ config: ResourceConfig) -> ResourceConfig {
        let proposer = coordinator.vote.createdByMemberId
            .flatMap { membersByMemberId[$0]?.profile?.displayName }
        return ResourceConfig(
            identity: config.identity,
            accent: config.accent,
            hero: config.hero,
            actions: config.actions,
            sections: config.sections,
            activity: config.activity,
            toolbarMenu: config.toolbarMenu,
            groupContext: GroupContextData(
                groupName: coordinator.group.name,
                groupInitials: Self.groupInitials(coordinator.group.name),
                proposedBy: proposer,
                proposedAt: coordinator.vote.openedAt,
                // Tap on group → dismiss the vote detail to return to
                // wherever the user opened it from (Inbox / GroupHome /
                // votes list). Direct "open GroupHome" navigation is a
                // V1.5 follow-up that needs router access here.
                onTapGroup: { dismiss() }
            )
        )
    }

    @MainActor
    private func loadMembers() async {
        let rows = (try? await app.groupsRepo.membersWithProfiles(of: coordinator.group.id)) ?? []
        var dir: [UUID: MemberWithProfile] = [:]
        for row in rows { dir[row.member.id] = row }
        membersByMemberId = dir
    }

    private static func groupInitials(_ name: String) -> String {
        let chars = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    private static func statusLabel(for vote: Vote, counts: VoteCounts?) -> String {
        switch vote.status {
        case .open:      return "Abierta"
        case .closed:    return "Cerrada"
        case .resolved:
            switch counts?.resolution {
            case .passed:        return "Aprobada"
            case .failed:        return "Rechazada"
            case .quorumFailed:  return "Sin quórum"
            case .none:          return "Resuelta"
            }
        case .quorumFailed: return "Sin quórum"
        case .cancelled:    return "Cancelada"
        }
    }

    private static func voteTypeLabel(_ type: VoteType) -> String {
        switch type {
        case .fineAppeal:      return "Apelación de multa"
        case .ruleChange:      return "Cambio de regla"
        case .ruleRepeal:      return "Derogación de regla"
        case .memberRemoval:   return "Expulsión de miembro"
        case .fundWithdrawal:  return "Retiro de fondo"
        case .roleAssignment:  return "Asignación de rol"
        case .generalProposal: return "Propuesta general"
        case .slotDispute:     return "Disputa de turno"
        case .ledgerReview:    return "Revisión de movimiento"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    private static func timingLabel(for vote: Vote) -> String {
        let rel = relativeFormatter.localizedString(for: vote.closesAt, relativeTo: .now)
        if vote.status == .open {
            return "Cierra \(rel)"
        }
        if let resolvedAt = vote.resolvedAt {
            return "Cerró \(relativeFormatter.localizedString(for: resolvedAt, relativeTo: .now))"
        }
        return "Cerró \(rel)"
    }

    private static func mapActivityEntry(_ entry: ActivityEntry) -> ActivityItem {
        ActivityItem(
            id: entry.id.uuidString,
            title: entry.sentence,
            subtitle: nil,
            timestamp: .now,
            icon: entry.icon,
            kind: .neutral,
            prebakedRelativeTime: entry.relativeTime
        )
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
        .presentationBackground(.ultraThinMaterial)
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
                    .buttonStyle(.glassProminent)
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
                    .buttonStyle(.glass)
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
        .presentationBackground(.ultraThinMaterial)
    }
}
