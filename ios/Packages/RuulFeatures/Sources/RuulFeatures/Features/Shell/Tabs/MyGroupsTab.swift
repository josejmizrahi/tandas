import SwiftUI
import RuulCore
import RuulUI

/// "Grupo" tab — single-group surface driven by `app.homeScope`.
/// Mirrors the Inicio tab's scope switcher (toolbar leading pill +
/// `ToolbarTitleMenu`) so the user picks which group is in scope from
/// either tab. The main content is always `GroupSpaceView` for the
/// scoped group; when scope is `.all` we surface a "pick a group"
/// state pointing at the switcher.
///
/// Navigation hierarchy:
///   - GroupSpaceView (root) — presence + chips + tiles + stream
///   - Decisiones tile/chip      → `.reglas`  (RulesView)
///   - Avatar stack tap          → `.personas` (MembersListView)
///   - Stream "Ver todo"         → `.actividad` (ActivityView)
///   - Toolbar "⋯" → Ajustes     → `.ajustes` (GroupAjustesView)
///       └→ Roles del grupo      → `.roles` / `.tiposDeRol`
///       └→ Cómo se aprueban votos → `.governance` (quórum/threshold)
///       └→ Plantillas / Modules → `.rulePresets` / `.modules`
///       └→ Moneda / Zona        → `.currency` / `.timezone`
@MainActor
public struct MyGroupsTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    @State private var navPath = NavigationPath()

    // Lifted sheet state — both `GroupSpaceScreen` and `GroupAjustesView`
    // trigger the same modals. Mounting them at tab level guarantees
    // a single presentation point regardless of which surface fires.
    @State private var showEditIdentity = false
    @State private var showRotateCode = false
    @State private var showInvite = false
    @State private var showLeave = false
    @State private var showArchiveConfirm = false
    @State private var archiveError: String?

    public init() {}

    public enum GroupDestination: Hashable {
        // Decisiones tile → open votes (votes in progress).
        // Reglas vigentes (the WHEN/IF/THEN policy list) is a
        // separate destination reached from Ajustes.
        case decisiones
        case reglas
        // Resource list surfaces (Spaces grid tiles)
        case eventos
        case multas
        case fondos
        case activos
        case balances
        // Money UX Consolidation 2026-05-24 — split the hub into
        // dashboard + drill-downs. Balances stays as the dashboard;
        // these two are the "Ver todas →" / "Ver plan completo →"
        // destinations.
        case transacciones
        case liquidacion
        // Ajustes hierarchy
        case ajustes
        case roles            // assignments: members grouped by role
        case tiposDeRol       // catalog: role definitions (admin editor)
        case governance       // quórum + threshold
        case rulePresets
        case modules
        case currency
        case timezone
        // People + activity
        case personas
        case actividad
    }

    public var body: some View {
        NavigationStack(path: $navPath) {
            content
                .navigationTitle("Grupo")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .navigationDestination(for: GroupDestination.self) { dest in
                    destinationView(for: dest)
                }
                .onChange(of: app.homeScope) { _, _ in
                    navPath = NavigationPath()
                }
        }
        .fullScreenCover(isPresented: $showEditIdentity) {
            if let g = scopedGroup {
                EditGroupIdentitySheet(groupId: g.id)
                    .environment(app)
                    .presentationBackground(.regularMaterial)
            }
        }
        .fullScreenCover(isPresented: $showRotateCode) {
            if let g = scopedGroup {
                RegenerateInviteCodeSheet(groupId: g.id)
                    .environment(app)
                    .presentationBackground(.regularMaterial)
            }
        }
        .fullScreenCover(isPresented: $showInvite) {
            if let g = scopedGroup {
                InviteMembersFromGroupView(group: g)
                    .environment(app)
                    .presentationBackground(.regularMaterial)
            }
        }
        .fullScreenCover(isPresented: $showLeave) {
            if let g = scopedGroup {
                LeaveGroupConfirmationSheet(group: g)
                    .environment(app)
                    .presentationBackground(.regularMaterial)
            }
        }
        .confirmationDialog(
            scopedGroup.map { "¿Archivar \($0.name)?" } ?? "Archivar grupo",
            isPresented: $showArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button("Archivar grupo", role: .destructive) {
                Task { await archiveScopedGroup() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se ocultará de tu lista de grupos. Su historia, multas e historia se mantienen y puedes restaurarlo después.")
        }
        .alert("No pudimos archivar", isPresented: Binding(
            get: { archiveError != nil },
            set: { if !$0 { archiveError = nil } }
        )) {
            Button("OK", role: .cancel) { archiveError = nil }
        } message: {
            Text(archiveError ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if app.groups.isEmpty {
            emptyHero
        } else if let group = scopedGroup {
            // `.id(group.id)` forces SwiftUI to recreate the screen
            // (and its `@State coordinator`) when the user picks a
            // different group from the switcher. Without this, the
            // coordinator stays bound to the previously-selected
            // group and the new selection appears to do nothing.
            GroupSpaceScreen(
                group: group,
                path: $navPath,
                showInvite: $showInvite,
                showLeave: $showLeave
            )
            .id(group.id)
        } else {
            pickGroupHero
                .task {
                    if app.homeScope == .all {
                        let target = app.activeGroup ?? app.groups.first
                        if let target {
                            app.homeScope = .group(target.id)
                            if app.activeGroupId != target.id {
                                app.activeGroupId = target.id
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func destinationView(for dest: GroupDestination) -> some View {
        if let group = scopedGroup {
            switch dest {
            case .decisiones:
                OpenVotesListView(
                    coordinator: OpenVotesCoordinator(
                        group: group,
                        voteRepo: app.voteRepo,
                        userMemberId: nil
                    ),
                    onSelectVote: { vote in
                        router.openVoteDetail(VoteDetailRouteContext(vote: vote))
                    },
                    onCreateVote: {
                        router.present(.createVotePicker)
                    }
                )
                .environment(app)

            case .reglas:
                if let coord = router.state.rulesCoordinator {
                    RulesView(
                        coordinator: coord,
                        voteRepo: app.voteRepo,
                        policyRepo: app.policyRepo,
                        actorUserId: app.session?.user.id ?? UUID(),
                        userActionRepo: app.userActionRepo,
                        ruleTemplates: app.ruleTemplates,
                        ruleTemplateRepo: app.ruleTemplateRepo
                    )
                    .environment(app)
                } else {
                    ProgressView()
                }

            case .eventos:
                GroupEventsListView(
                    group: group,
                    onOpenEvent: { router.openEvent($0) }
                )
                .environment(app)

            case .multas:
                GroupFinesListView(
                    group: group,
                    onOpenFine: { router.openFine($0) }
                )
                .environment(app)

            case .fondos:
                GroupFundsListView(
                    group: group,
                    onOpenFund: { fund in
                        // `router.openResource(id:)` pushes `.eventDetail`
                        // (legacy shape — only correct for events). For
                        // polymorphic resources (fund/asset/space/slot)
                        // we need the full `ResourceRow` so the cover
                        // mounts `ResourceDetailSheet`. Fetch and route.
                        Task {
                            if let row = try? await app.resourceRepo.resource(fund.fundId) {
                                router.openResource(row)
                            }
                        }
                    },
                    onCreate: {
                        router.state.pendingWizardResourceType = .fund
                        router.present(.createCover)
                    }
                )
                .environment(app)

            case .activos:
                GroupAssetsListView(
                    group: group,
                    onOpenAsset: { asset in
                        // Asset already IS a ResourceRow — no fetch needed.
                        // Routes through the universal ResourceDetailSheet
                        // which mounts the Money Block via makeGenericConfig
                        // (Phase 4 brick C.1).
                        router.openResource(asset)
                    },
                    onCreate: {
                        router.state.pendingWizardResourceType = .asset
                        router.present(.createCover)
                    }
                )
                .environment(app)

            case .balances:
                // SharedMoney P3 / Money UX Consolidation PR-A
                // (2026-05-24): "Dinero del grupo" hub now lists
                // legacy/protected funds INLINE (not via a separate
                // GroupFundsListView screen) — answers founder's
                // "porque tenemos dos vistas diferentes?". The
                // .fondos NavigationPath destination is kept as a
                // deeplink/back-compat path but no primary surface
                // links to it anymore.
                GroupBalancesView(
                    group: group,
                    onOpenFund: { fund in
                        Task {
                            if let row = try? await app.resourceRepo.resource(fund.fundId) {
                                router.openResource(row)
                            }
                        }
                    },
                    onCreateFund: {
                        router.state.pendingWizardResourceType = .fund
                        router.present(.createCover)
                    },
                    onOpenAllTransactions: {
                        navPath.append(MyGroupsTab.GroupDestination.transacciones)
                    },
                    onOpenSettlementPlan: {
                        navPath.append(MyGroupsTab.GroupDestination.liquidacion)
                    }
                )
                .environment(app)

            case .transacciones:
                GroupTransactionsView(group: group)
                    .environment(app)

            case .liquidacion:
                GroupSettlementPlanView(group: group)
                    .environment(app)

            case .ajustes:
                GroupAjustesView(
                    group: group,
                    activeModulesCount: group.activeModules?.count ?? 0,
                    onEditIdentity:        { showEditIdentity = true },
                    onPickCurrency:        { navPath.append(GroupDestination.currency) },
                    onPickTimezone:        { navPath.append(GroupDestination.timezone) },
                    onPickModules:         { navPath.append(GroupDestination.modules) },
                    onOpenRoles:           { navPath.append(GroupDestination.roles) },
                    onOpenDecisiones:      { navPath.append(GroupDestination.decisiones) },
                    onOpenGovernance:      { navPath.append(GroupDestination.governance) },
                    onOpenReglas:          { navPath.append(GroupDestination.reglas) },
                    onOpenEventsList:      { navPath.append(GroupDestination.eventos) },
                    onOpenAssetsList:      { navPath.append(GroupDestination.activos) },
                    onOpenFundsList:       { navPath.append(GroupDestination.fondos) },
                    onRotateCode:          { showRotateCode = true },
                    onArchiveGroup:        { showArchiveConfirm = true },
                    onLeaveGroup:          { showLeave = true }
                )

            case .roles:
                GroupRolesAssignmentsView(
                    coordinator: MembersCoordinator(
                        group: group,
                        actorUserId: app.session?.user.id ?? UUID(),
                        groupsRepo: app.groupsRepo
                    )
                )
                .environment(app)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            navPath.append(GroupDestination.tiposDeRol)
                        } label: {
                            Label("Tipos de rol", systemImage: "tag")
                        }
                        .accessibilityLabel("Editar tipos de rol")
                    }
                }

            case .tiposDeRol:
                GroupRolesSheet(groupId: group.id)
                    .environment(app)

            case .governance:
                GovernanceView(group: group, onSaved: nil)
                    .environment(app)

            case .rulePresets:
                RulePresetsView(coordinator: GroupRulesCoordinator(
                    group: group,
                    actorUserId: app.session?.user.id ?? UUID(),
                    policyRepo: app.policyRepo
                ))
                .environment(app)

            case .modules:
                ModulesPickerView(groupId: group.id)
                    .environment(app)

            case .personas:
                MembersListView(coordinator: MembersCoordinator(
                    group: group,
                    actorUserId: app.session?.user.id ?? UUID(),
                    groupsRepo: app.groupsRepo
                ))
                .environment(app)

            case .actividad:
                ActivityView(coordinator: ActivityCoordinator(
                    groupId: group.id,
                    repo: app.systemEventRepo,
                    groupsRepo: app.groupsRepo,
                    resourceRepo: app.resourceRepo
                ))
                .environment(app)

            case .currency:
                GroupCurrencyPickerView(groupId: group.id)
                    .environment(app)

            case .timezone:
                GroupTimezonePickerView(groupId: group.id)
                    .environment(app)
            }
        } else {
            ContentUnavailableView(
                "No hay grupo activo",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private var scopedGroup: RuulCore.Group? {
        switch app.homeScope {
        case .group(let id): return app.groups.first(where: { $0.id == id })
        case .all:           return nil
        }
    }

    private func archiveScopedGroup() async {
        guard let g = scopedGroup else { return }
        do {
            try await app.groupsRepo.archive(groupId: g.id)
            await app.refreshProfileAndGroups()
            app.homeScope = .all
        } catch {
            archiveError = "No pudimos archivar el grupo. Intenta de nuevo."
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarTitleMenu {
            scopeMenuButtons
        }
        ToolbarItem(placement: .topBarLeading) {
            scopeSwitcherButton
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    router.present(.createGroup)
                } label: {
                    Label("Crear grupo", systemImage: "plus")
                }
                Button {
                    router.present(.joinGroup)
                } label: {
                    Label("Unirme con código", systemImage: "qrcode")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Agregar grupo")
        }
    }

    @ViewBuilder
    private var scopeMenuButtons: some View {
        Button {
            pickScope(.all)
        } label: {
            Label("Todos los grupos", systemImage: "square.grid.2x2")
        }
        if !app.groups.isEmpty {
            Divider()
            ForEach(app.groups, id: \.id) { group in
                Button {
                    pickScope(.group(group.id))
                } label: {
                    Label(group.name, systemImage: "person.3.fill")
                }
            }
        }
    }

    private var scopeSwitcherButton: some View {
        Menu {
            scopeMenuButtons
        } label: {
            HStack(spacing: 4) {
                scopeAvatar
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Cambiar grupo")
    }

    @ViewBuilder
    private var scopeAvatar: some View {
        switch app.homeScope {
        case .all:
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 28, height: 28)
                Image(systemName: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        case .group(let id):
            if let group = app.groups.first(where: { $0.id == id }) {
                RuulGroupAvatar(group: group, size: .md)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func pickScope(_ scope: AppState.HomeScope) {
        app.homeScope = scope
        if case let .group(id) = scope, app.activeGroupId != id {
            app.activeGroupId = id
        }
    }

    // MARK: - Empty states

    private var pickGroupHero: some View {
        ContentUnavailableView {
            Label("Selecciona un grupo", systemImage: "person.3")
        } description: {
            Text("Toca el avatar arriba para elegir un grupo.")
        }
    }

    private var emptyHero: some View {
        ContentUnavailableView {
            Label("Empieza un grupo", systemImage: "person.3")
        } description: {
            Text("Crea uno tuyo o únete con un código para coordinar con tus amigos.")
        } actions: {
            Button("Crear grupo") { router.present(.createGroup) }
                .buttonStyle(.borderedProminent)
            Button("Unirme con código") { router.present(.joinGroup) }
        }
    }
}

// MARK: - GroupSpaceScreen host

/// Owns the `GroupHomeCoordinator` lifecycle and wires the new
/// `GroupSpaceView` into the Grupo tab's NavigationStack. Sheet state
/// is owned by the parent `MyGroupsTab` and passed in as bindings
/// (invite + leave fire from here; edit / rotate / archive fire from
/// the pushed Ajustes view — same bindings, same sheets).
@MainActor
private struct GroupSpaceScreen: View {
    let group: RuulCore.Group
    @Binding var path: NavigationPath
    @Binding var showInvite: Bool
    @Binding var showLeave: Bool
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    @State private var coordinator: GroupHomeCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                GroupSpaceView(
                    coordinator: coordinator,
                    onCreateEvent: { router.present(.createCover) },
                    onStartVote:      { router.present(.createVotePicker) },
                    onInviteMembers:  { showInvite = true },
                    onShareInvite:    { router.present(.inviteShare) },
                    onOpenEvent:      { event in router.openEvent(event) },
                    onSelectPending:  { action in
                        Task { await handleInboxAction(action) }
                    },
                    onOpenMembers:    { path.append(MyGroupsTab.GroupDestination.personas) },
                    onOpenActivity:   { path.append(MyGroupsTab.GroupDestination.actividad) },
                    onOpenTransactions: { path.append(MyGroupsTab.GroupDestination.transacciones) },
                    onOpenEventsHistory: { path.append(MyGroupsTab.GroupDestination.eventos) },
                    onOpenAjustes:    { path.append(MyGroupsTab.GroupDestination.ajustes) },
                    onConfirmLeave:   { showLeave = true },
                    onLeaveGroup: {
                        Task {
                            try? await app.groupsRepo.leave(group.id)
                            await app.refreshProfileAndGroups()
                            app.homeScope = .all
                        }
                    }
                )
            } else {
                Color.clear
            }
        }
        .task(id: group.id) {
            if coordinator?.groupId != group.id {
                coordinator = GroupHomeCoordinator(
                    groupId: group.id,
                    groupsRepo: app.groupsRepo,
                    groupSummaryRepo: app.groupSummaryRepo,
                    userActionRepo: app.userActionRepo,
                    myActivityRepo: app.myActivityRepo,
                    eventRepo: app.eventRepo,
                    fineRepo: app.fineRepo,
                    fundRepo: app.fundRepo,
                    resourceRepo: app.resourceRepo,
                    ledgerRepo: app.ledgerRepo,
                    actorUserId: app.session?.user.id,
                    changeFeed: app.multiDeviceChangeFeed
                )
            }
        }
        // Refresh on cover-dismiss. Any compose flow (createCover,
        // createVotePicker, inviteShare, etc.) pushes a cover onto
        // `router.state.activeRoutes` and pops it on completion — so a
        // strictly-decreasing count is the canonical signal that "a
        // compose flow just finished, your counts are stale".
        .onChange(of: router.state.activeRoutes.count) { oldCount, newCount in
            guard newCount < oldCount, let coord = coordinator else { return }
            Task { await coord.refresh() }
        }
        .onChange(of: showInvite) { _, presented in
            if !presented, let coord = coordinator { Task { await coord.refresh() } }
        }
    }

    /// Per-`ActionType` routing for the Pendings block. Mirrors the
    /// dispatch logic in `HomeTab.handleInboxAction` so a tap from the
    /// group home lands on the same destination as a tap from the
    /// cross-group inbox.
    private func handleInboxAction(_ action: UserAction) async {
        if app.activeGroupId != action.groupId {
            app.activeGroupId = action.groupId
        }

        switch action.actionType {
        case .finePending, .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFine(fine)
            }
        case .fineProposalReview, .rsvpPending, .hostAssigned:
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.openEvent(event)
            }
        case .appealVotePending:
            if let appeal = try? await app.appealRepo.appeal(id: action.referenceId),
               let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                router.openVoteOnAppeal(AppealRouteContext(appeal: appeal, fine: fine))
            }
        case .votePending, .ruleChangeApplyPending:
            if let vote = try? await app.voteRepo.vote(id: action.referenceId) {
                router.openVoteDetail(VoteDetailRouteContext(vote: vote))
            }
        case .assetActionApproval, .slotPending,
             .contributionDue, .compensationDue:
            // Polymorphic resources (asset/slot/fund): fetch the
            // `ResourceRow` so the cover mounts `ResourceDetailSheet`
            // via `router.openResource(_ row:)`. The legacy
            // `openResource(id:)` pushes `.eventDetail` and is wrong
            // for non-event types.
            if let row = try? await app.resourceRepo.resource(action.referenceId) {
                router.openResource(row)
            }
        }
    }
}
