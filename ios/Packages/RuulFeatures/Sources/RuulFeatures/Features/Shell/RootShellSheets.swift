import SwiftUI
import RuulCore
import RuulUI

/// ViewModifier that attaches every sheet / fullScreenCover to the shell
/// root view. Each branch maps one `RootRoute` case to its presentation.
///
/// Object payloads (Event, CheckInScannerCoordinator) live in
/// `RootShellState` — callers must populate them before pushing the route.
/// Coordinator handles are also read from state; they are populated by
/// `RootShell.rebuildCoordinators` (Task 9).
///
/// Navigation push destinations (past, feed, groupHistory, acuerdos,
/// sanciones, fineDetail, voteDetail, openVotes) are NOT handled here —
/// they are `.navigationDestination` pushes inside the per-tab stacks and
/// will be wired during Pass-1 Task 9.
@MainActor
public struct RootShellSheets: ViewModifier {
    @Environment(AppState.self) var app  // internal — extension files in this target need read access
    let router: RootRouter

    public func body(content: Content) -> some View {
        content
            // MARK: Group management sheets
            .fullScreenCover(isPresented: boolBinding(for: .groupSwitcher)) {
                GroupSwitcherSheet(
                    onCreateGroup: { router.present(.createGroup) },
                    onJoinGroup: { router.present(.joinGroup) }
                )
                .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: boolBinding(for: .createGroup)) {
                CreateGroupSheet { _ in
                    // AppState.activeGroupId is set inside the sheet;
                    // RootShell.rebuildCoordinators fires reactively.
                }
                .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: boolBinding(for: .joinGroup)) {
                JoinGroupSheet { _ in
                    // Same: group switch is reactive via activeGroupId.
                }
                .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: boolBinding(for: .inviteShare)) {
                Group {
                    if let activeGroup = app.activeGroup {
                        GroupHomeSheetContent(group: activeGroup, app: app, router: router)
                    }
                }
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: boolBinding(for: .groupRulesSettings)) {
                Group {
                    if let group = app.activeGroup {
                        RulePresetsView(coordinator: GroupRulesCoordinator(
                            group: group,
                            actorUserId: app.session?.user.id ?? UUID(),
                            policyRepo: app.policyRepo
                        ))
                        .environment(app)
                    }
                }
                .presentationBackground(.thickMaterial)
            }

            // MARK: Group home cover (Nivel 1 group dashboard)
            .fullScreenCover(isPresented: boolBinding(for: .groupHome)) {
                Group {
                    if let activeGroup = app.activeGroup {
                        GroupHomeSheetContent(group: activeGroup, app: app, router: router)
                    }
                }
                .presentationBackground(.thickMaterial)
            }

            // V2 Slice 4C: .acuerdos root cover removed. RulesView now
            // lives as a Group-sheet NavigationStack push (GroupNav.acuerdos
            // below) — the canonical entry the original Pass-1 plan called
            // for. Per V2 Plan §B.1: "one entry per destination".

            // MARK: Rule edit sheet (carries RuleEditRouteContext)
            .fullScreenCover(item: ruleEditItem, onDismiss: {
                Task { await router.state.refreshInboxes() }
            }) { ctx in
                ruleEditSheet(ctx)
                    .presentationBackground(.thickMaterial)
            }

            // MARK: Resource creation cover (value-less; "+" tab intercept)
            // Cutover gate (2026-05-18 doctrine "Create simple. Configure
            // by intent. Capabilities stay invisible. Advanced stays
            // available."). DEBUG builds default to the new flow;
            // release defaults to legacy until founder smoke pass.
            // Flip live via `ResourceCreationFeatureFlag.isEnabled = ...`.
            .fullScreenCover(isPresented: boolBinding(for: .createCover)) {
                Group {
                    if let group = app.activeGroup {
                        resourceCreationCover(group: group)
                    }
                }
                .presentationBackground(.thickMaterial)
            }

            // MARK: Event detail (item: state.activeEvent)
            // App-wide policy 2026-05-15: every modal route is a
            // `.fullScreenCover` — full takeovers with an explicit
            // close action, not partial-overlap sheets.
            .fullScreenCover(item: activeEventItem, onDismiss: {
                Task {
                    async let h: Void = router.state.homeCoordinator?.refresh(force: true) ?? ()
                    async let i: Void? = router.state.refreshInboxes()
                    _ = await (h, i)
                }
            }) { wrappedEvent in
                eventDetailScreen(wrappedEvent.event)
                    .presentationBackground(.thickMaterial)
            }

            // MARK: Polymorphic resource detail (fund/asset/space/slot/right)
            // Routed via `RootRoute.resourceDetail` + `state.activeResource`.
            // Renders ResourceDetailSheet which wraps UniversalResourceDetailView
            // for non-event resource types. Events keep their own dedicated
            // cover above because EventDetailHost needs the full Event.
            .fullScreenCover(item: activeResourceItem, onDismiss: {
                Task {
                    await router.state.homeCoordinator?.refresh(force: true)
                }
            }) { wrappedResource in
                ResourceDetailSheet(resource: wrappedResource.resource)
                    .environment(app)
                    .environment(router)
                    .presentationBackground(.thickMaterial)
            }

            // MARK: Event edit cover (item: state.activeEditEvent)
            .fullScreenCover(item: activeEditEventItem) { wrappedEvent in
                eventEditScreen(wrappedEvent.event)
                .presentationBackground(.thickMaterial)
            }

            // MARK: Scanner cover (item: state.activeScannerCoordinator)
            .fullScreenCover(item: activeScannerItem) { wrappedCoord in
                CheckInScannerView(coordinator: wrappedCoord.coordinator)
            }

            // MARK: Vote-on-appeal sheet (carries AppealRouteContext)
            .sheet(item: appealItem) { ctx in
                voteOnAppealSheet(ctx)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial.opacity(0.5))
            }

            // V2 Slice 4A: .editProfile cover removed. EditProfileSheet
            // now presents from ProfileTab's local @State (one entry per
            // destination per V2 Plan §B.1).

            // V2 Slice 4B: .membersList + .membersAdmin root covers
            // removed. Both were orphaned (zero external callers); the
            // canonical entry is the Group sheet NavigationStack push
            // (GroupNav.membersList / .membersAdmin) still wired below.
            // Per V2 Plan §B.1: "one entry per destination".

            // MARK: Create-vote picker sheet
            .fullScreenCover(isPresented: boolBinding(for: .createVotePicker)) {
                CreateVoteSheet(
                    onPickGeneralProposal: { router.present(.createGeneralProposal) },
                    onPickRuleChange: { router.present(.createRuleChange(nil)) },
                    onPickMemberRemoval: { router.present(.createMemberRemoval) }
                )
                .presentationBackground(.thickMaterial)
            }

            // MARK: Create general proposal sheet
            .fullScreenCover(isPresented: boolBinding(for: .createGeneralProposal), onDismiss: {
                Task {
                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                    async let i: Void? = router.state.refreshInboxes()
                    _ = await (r, i)
                }
            }) {
                Group {
                    if let group = app.activeGroup,
                       let member = currentGroupMember(in: group) {
                        CreateGeneralProposalSheet(
                            coordinator: CreateGeneralProposalCoordinator(
                                group: group,
                                member: member,
                                voteRepo: app.voteRepo,
                                governance: app.governance
                            ),
                            onCreated: { _ in
                                Task {
                                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                                    async let i: Void? = router.state.refreshInboxes()
                                    _ = await (r, i)
                                }
                            }
                        )
                    }
                }
                .presentationBackground(.thickMaterial)
            }

            // MARK: Create rule-change sheet (carries optional GroupRule)
            .fullScreenCover(item: createRuleChangeItem, onDismiss: {
                Task {
                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                    async let i: Void? = router.state.refreshInboxes()
                    _ = await (r, i)
                }
            }) { wrapper in
                Group {
                    if let group = app.activeGroup,
                       let member = currentGroupMember(in: group) {
                        CreateRuleChangeSheet(
                            coordinator: CreateRuleChangeCoordinator(
                                group: group,
                                member: member,
                                availableRules: router.state.rulesCoordinator?.rules ?? [],
                                voteRepo: app.voteRepo,
                                governance: app.governance
                            ),
                            onCreated: { _ in
                                Task {
                                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                                    async let i: Void? = router.state.refreshInboxes()
                                    _ = await (r, i)
                                }
                            }
                        )
                    }
                    let _ = wrapper // silence unused-variable warning; wrapper.rule available if needed
                }
                .presentationBackground(.thickMaterial)
            }

            // MARK: Create member-removal sheet
            .fullScreenCover(isPresented: boolBinding(for: .createMemberRemoval), onDismiss: {
                Task {
                    async let i: Void? = router.state.refreshInboxes()
                    _ = await i
                }
            }) {
                Group {
                    if let group = app.activeGroup,
                       let member = currentGroupMember(in: group) {
                        CreateMemberRemovalSheet(
                            coordinator: CreateMemberRemovalCoordinator(
                                group: group,
                                creatorMemberId: member.id,
                                prefilledTarget: nil,
                                voteRepo: app.voteRepo,
                                groupsRepo: app.groupsRepo
                            )
                        )
                    }
                }
                .presentationBackground(.thickMaterial)
            }

            // MARK: Fine detail cover (item: state.activeFine)
            // Originally planned as a per-tab navigationDestination push, but
            // no tab actually wired the destination so the route was dead —
            // tapping a `.finePending` action on Home / Inbox pushed the
            // route to `state.activeRoutes` and nothing happened. Presenting
            // as a fullScreenCover mirrors the eventDetail flow and makes
            // the route reachable from every tab.
            .fullScreenCover(item: activeFineItem, onDismiss: {
                Task {
                    await router.state.refreshInboxes()
                    await router.state.myFinesCoordinator?.refresh()
                }
            }) { wrappedFine in
                fineDetailScreen(wrappedFine.fine)
                    .presentationBackground(.thickMaterial)
            }

            // V2 Slice 4D: .sanciones cover removed. MyFinesScreenHost
            // now presents from ProfileTab's local @State. Cross-tab
            // entries (Group sheet's "Mis multas") go through
            // `router.requestOpenMyFines()` which switches to Profile
            // and raises `pendingOpenMyFines`. Per V2 Plan §B.1.

            // MARK: Past events cover (Home → "Ver historial")
            .fullScreenCover(isPresented: boolBinding(for: .past)) {
                pastEventsScreen
                    .presentationBackground(.thickMaterial)
            }

            // MARK: Vote detail cover (.votePending inbox action)
            .fullScreenCover(item: voteDetailItem) { ctx in
                voteDetailScreen(ctx)
                .presentationBackground(.thickMaterial)
            }

            // MARK: Navigation-push routes (no sheet presentation)
            // feed, groupHistory, openVotes have no callers in the current
            // shell — when callers are added, surface them with the same
            // fullScreenCover pattern as the fine / past / voteDetail
            // branches above.
    }

}

// MARK: - GroupHomeSheetContent

@MainActor
private struct GroupHomeSheetContent: View {
    let group: RuulCore.Group
    let app: AppState
    let router: RootRouter

    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var showEditIdentity = false
    @State private var showRotateCode = false
    @State private var showInvite = false
    @State private var showLeave = false
    @State private var showMembersAdminInvite = false
    @State private var showArchiveConfirm = false
    @State private var archiveError: String?

    private enum GroupNav: Hashable {
        case modules, currency, timezone, governance, rulePresets,
             membersList, membersAdmin, roles, acuerdos
    }

    var body: some View {
        let coord = GroupHomeCoordinator(
            groupId: group.id,
            groupsRepo: app.groupsRepo,
            groupSummaryRepo: app.groupSummaryRepo,
            actorUserId: app.session?.user.id
        )
        NavigationStack(path: $path) {
            GroupHomeView(
                coordinator: coord,
                onOpenMembersList: { path.append(GroupNav.membersList) },
                onOpenMembersAdmin: { path.append(GroupNav.membersAdmin) },
                onOpenGovernance: { path.append(GroupNav.governance) },
                onOpenRulePresets: { path.append(GroupNav.rulePresets) },
                onLeaveGroup: {
                    Task {
                        try? await app.groupsRepo.leave(group.id)
                        await app.refreshProfileAndGroups()
                        while router.state.contains(.groupHome) { router.state.dismissTop() }
                        while router.state.contains(.inviteShare) { router.state.dismissTop() }
                    }
                },
                onShareInvite: { router.present(.inviteShare) },
                onEditIdentity: { showEditIdentity = true },
                onPickModules: { path.append(GroupNav.modules) },
                onPickCurrency: { path.append(GroupNav.currency) },
                onPickTimezone: { path.append(GroupNav.timezone) },
                onRotateCode: { showRotateCode = true },
                onInviteMembers: { showInvite = true },
                onConfirmLeave: { showLeave = true },
                onOpenRoles: { path.append(GroupNav.roles) },
                onArchiveGroup: { showArchiveConfirm = true },
                onOpenMyLedger: nil,
                onOpenMyFines: {
                    // V2 Slice 4D: dismiss the Group sheet first so the
                    // cross-tab deep link doesn't stack on top of it.
                    // requestOpenMyFines switches to .profile and raises
                    // the flag ProfileTab observes.
                    while router.state.contains(.groupHome) { router.state.dismissTop() }
                    router.requestOpenMyFines()
                },
                onOpenVotes: {
                    router.openOpenVotes(OpenVotesRouteContext(id: group.id))
                },
                onOpenInbox: { router.selectTab(.home) },
                onOpenAcuerdos: { path.append(GroupNav.acuerdos) }
            )
            .navigationDestination(for: GroupNav.self) { dest in
                switch dest {
                case .modules:
                    ModulesPickerView(groupId: group.id)
                        .environment(app)
                case .currency:
                    GroupCurrencyPickerView(groupId: group.id)
                        .environment(app)
                case .timezone:
                    GroupTimezonePickerView(groupId: group.id)
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
                case .membersList:
                    MembersListView(coordinator: MembersCoordinator(
                        group: group,
                        actorUserId: app.session?.user.id ?? UUID(),
                        groupsRepo: app.groupsRepo
                    ))
                    .environment(app)
                case .membersAdmin:
                    MembersAdminView(
                        coordinator: MembersCoordinator(
                            group: group,
                            actorUserId: app.session?.user.id ?? UUID(),
                            groupsRepo: app.groupsRepo
                        ),
                        onInviteTap: { showMembersAdminInvite = true }
                    )
                    .environment(app)
                case .roles:
                    GroupRolesSheet(groupId: group.id)
                        .environment(app)
                case .acuerdos:
                    // V2 Slice 4C: Acuerdos used to live behind a global
                    // `.acuerdos` root cover. Promoted here as a Group-
                    // sheet nav push — one entry per destination per V2
                    // Plan §B.1. RulesCoordinator is set up at group-
                    // selection time so it's already available on the
                    // RootRouter state.
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
                }
            }
            .fullScreenCover(isPresented: $showMembersAdminInvite) {
                InviteMembersFromGroupView(group: group)
                    .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: $showEditIdentity) {
                EditGroupIdentitySheet(groupId: group.id)
                    .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: $showRotateCode) {
                RegenerateInviteCodeSheet(groupId: group.id)
                    .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: $showInvite) {
                InviteMembersFromGroupView(group: group)
                    .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .fullScreenCover(isPresented: $showLeave) {
                LeaveGroupConfirmationSheet(group: group)
                    .environment(app)
                .presentationBackground(.thickMaterial)
            }
            .confirmationDialog(
                "¿Archivar \(group.name)?",
                isPresented: $showArchiveConfirm,
                titleVisibility: .visible
            ) {
                Button("Archivar grupo", role: .destructive) {
                    Task { await archiveGroup() }
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
            .toolbar {
                // GroupHomeView itself has no close affordance — the
                // fullScreenCover that hosts it needs to provide one or
                // the screen becomes a dead-end. Matches the chrome
                // pattern of every other modal in the app (Switcher,
                // CreateGroup, Members*, etc.).
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .environment(app)
    }

    /// Soft-delete vía `archive_group` RPC (mig 00094+). El grupo queda
    /// invisible para `listMine()` pero su historia + ledger + atoms
    /// permanecen. Tras éxito: refresh la lista de grupos del usuario,
    /// salta a otro grupo si el archivado era el activo, y dismissea el
    /// detail. Fallo: muestra alert sin cerrar el sheet.
    private func archiveGroup() async {
        do {
            try await app.groupsRepo.archive(groupId: group.id)
            await app.refreshProfileAndGroups()
            await MainActor.run {
                if app.activeGroup?.id == group.id {
                    app.activeGroupId = app.groups.first(where: { $0.id != group.id })?.id
                }
                while router.state.contains(.groupHome) { router.state.dismissTop() }
            }
        } catch {
            await MainActor.run {
                archiveError = error.localizedDescription
            }
        }
    }
}

// MARK: - Private wrapper types

/// Wraps `Event` in an `Identifiable` struct so `fullScreenCover(item:)`
/// can track it. Identity is the event's UUID.
internal struct IdentifiableEventWrapper: Identifiable, Hashable {
    let event: Event
    var id: UUID { event.id }
}

/// Wraps `ResourceRow` for the polymorphic resource detail cover.
/// Mirrors `IdentifiableEventWrapper` shape — identity is the row's UUID.
internal struct IdentifiableResourceWrapper: Identifiable, Hashable {
    let resource: ResourceRow
    var id: UUID { resource.id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Wraps `Fine` in an `Identifiable` struct so `fullScreenCover(item:)`
/// can drive the fine-detail cover via the shared `state.activeFine`
/// payload. Identity is the fine's UUID — re-presenting with the same
/// fine reuses the cover; a different fine triggers a fresh build.
internal struct IdentifiableFineWrapper: Identifiable, Hashable {
    let fine: Fine
    var id: UUID { fine.id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Wraps `CheckInScannerCoordinator` (which is a class) in a struct that is
/// both `Identifiable` and `Hashable`. Identity is the event UUID.
internal struct IdentifiableScannerWrapper: Identifiable, Hashable {
    let coordinator: CheckInScannerCoordinator
    var id: UUID { coordinator.event.id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Wraps the optional `GroupRule?` payload of `.createRuleChange` so
/// `sheet(item:)` has an `Identifiable` handle. Uses a stable UUID so
/// SwiftUI treats each presentation as a distinct sheet.
internal struct IdentifiableRuleChangeWrapper: Identifiable, Hashable {
    let rule: GroupRule?
    let id: UUID = UUID()
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rule?.id == rhs.rule?.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(rule?.id) }
}

// MARK: - MyFinesScreenHost
//
// Owns its own NavigationStack so the host cover (ProfileTab's local
// `.fullScreenCover` post-V2-Slice-4D) can navigate to a per-fine
// detail screen without colliding with the `.fineDetail` cover
// presenter at the shell level. The fine detail is pushed via the
// navigationDestination(for: Fine.self) inside this stack rather than
// going back through the router — that keeps the "open mis multas →
// tap a fine → tap close" flow inside one cover, with the standard
// nav-back affordance.
// File-internal so both ProfileTab (which presents it locally) and
// any legacy callers can reference it. Same module; no API change.
@MainActor
struct MyFinesScreenHost: View {
    @Environment(AppState.self) private var app
    @Bindable var coordinator: MyFinesCoordinator
    let onClose: () -> Void

    @State private var path: [Fine] = []

    var body: some View {
        NavigationStack(path: $path) {
            MyFinesView(coordinator: coordinator) { fine in
                path.append(fine)
            }
            .ruulSheetToolbar("Mis multas", onClose: onClose)
            .navigationDestination(for: Fine.self) { fine in
                fineDetailDestination(for: fine)
            }
        }
    }

    @ViewBuilder
    private func fineDetailDestination(for fine: Fine) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let fineCoord = FineDetailCoordinator(
            fine: fine,
            userId: userId,
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo,
            analytics: app.analytics,
            changeFeed: app.multiDeviceChangeFeed
        )
        FineDetailHost(coordinator: fineCoord, onViewAppeal: nil)
    }
}

// MARK: - MembersAdminViewWrapper

@MainActor
private struct MembersAdminViewWrapper: View {
    let group: RuulCore.Group
    let uid: UUID
    let app: AppState
    @State private var showInvite = false

    var body: some View {
        NavigationStack {
            MembersAdminView(
                coordinator: MembersCoordinator(group: group, actorUserId: uid, groupsRepo: app.groupsRepo),
                onInviteTap: { showInvite = true }
            )
            .environment(app)
        }
        .fullScreenCover(isPresented: $showInvite) {
            InviteMembersFromGroupView(group: group)
                .environment(app)
            .presentationBackground(.thickMaterial)
        }
    }
}

// MARK: - View extension

public extension View {
    func rootShellSheets(router: RootRouter) -> some View {
        modifier(RootShellSheets(router: router))
    }
}
