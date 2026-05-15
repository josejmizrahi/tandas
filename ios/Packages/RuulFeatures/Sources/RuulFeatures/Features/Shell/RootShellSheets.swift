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
    @Environment(AppState.self) private var app
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

            }
            .fullScreenCover(isPresented: boolBinding(for: .createGroup)) {
                CreateGroupSheet { _ in
                    // AppState.activeGroupId is set inside the sheet;
                    // RootShell.rebuildCoordinators fires reactively.
                }
                .environment(app)

            }
            .fullScreenCover(isPresented: boolBinding(for: .joinGroup)) {
                JoinGroupSheet { _ in
                    // Same: group switch is reactive via activeGroupId.
                }
                .environment(app)

            }
            .fullScreenCover(isPresented: boolBinding(for: .inviteShare)) {
                if let activeGroup = app.activeGroup {
                    GroupHomeSheetContent(group: activeGroup, app: app, router: router)
                }
            }
            .fullScreenCover(isPresented: boolBinding(for: .groupRulesSettings)) {
                if let group = app.activeGroup {
                    RulePresetsView(coordinator: GroupRulesCoordinator(
                        group: group,
                        actorUserId: app.session?.user.id ?? UUID(),
                        policyRepo: app.policyRepo
                    ))
                    .environment(app)

                }
            }

            // MARK: Group home cover (Nivel 1 group dashboard)
            .fullScreenCover(isPresented: boolBinding(for: .groupHome)) {
                if let activeGroup = app.activeGroup {
                    GroupHomeSheetContent(group: activeGroup, app: app, router: router)
                }
            }

            // MARK: Acuerdos / Rule list sheet (Beta 1 Rule Builder entry).
            // RootRoute.acuerdos was originally designed as a nav push in the
            // Pass-1 plan but no destination was wired in any tab. We render
            // it as a sheet here so the Beta 1 "+ Nueva regla" surface is
            // reachable; if the team later wires the navigation push, this
            // branch can be deleted without breaking the route.
            .fullScreenCover(isPresented: boolBinding(for: .acuerdos)) {
                if let coord = router.state.rulesCoordinator {
                    NavigationStack {
                        RulesView(
                            coordinator: coord,
                            voteRepo: app.voteRepo,
                            policyRepo: app.policyRepo,
                            actorUserId: app.session?.user.id ?? UUID(),
                            userActionRepo: app.userActionRepo,
                            ruleTemplates: app.ruleTemplates,
                            ruleTemplateRepo: app.ruleTemplateRepo
                        )
                    }
                    .environment(app)

                }
            }

            // MARK: Rule edit sheet (carries RuleEditRouteContext)
            .fullScreenCover(item: ruleEditItem, onDismiss: {
                Task { await router.state.inboxCoordinator?.refresh() }
            }) { ctx in
                ruleEditSheet(ctx)

            }

            // MARK: Resource creation cover (value-less; "+" tab intercept)
            .fullScreenCover(isPresented: boolBinding(for: .createCover)) {
                if let group = app.activeGroup {
                    ResourceWizardSheet(
                        group: group,
                        suggestedDate: nextDefaultDate(for: group),
                        onCreated: { _ in
                            Task {
                                await router.state.homeCoordinator?.refresh(force: true)
                            }
                        }
                    )

                }
            }

            // MARK: Event detail (item: state.activeEvent)
            // App-wide policy 2026-05-15: every modal route is a
            // `.fullScreenCover` — full takeovers with an explicit
            // close action, not partial-overlap sheets.
            .fullScreenCover(item: activeEventItem, onDismiss: {
                Task {
                    async let h: Void = router.state.homeCoordinator?.refresh(force: true) ?? ()
                    async let i: Void? = router.state.inboxCoordinator?.refresh()
                    _ = await (h, i)
                }
            }) { wrappedEvent in
                eventDetailScreen(wrappedEvent.event)

            }

            // MARK: Event edit cover (item: state.activeEditEvent)
            .fullScreenCover(item: activeEditEventItem) { wrappedEvent in
                eventEditScreen(wrappedEvent.event)
            }

            // MARK: Scanner cover (item: state.activeScannerCoordinator)
            .fullScreenCover(item: activeScannerItem) { wrappedCoord in
                CheckInScannerView(coordinator: wrappedCoord.coordinator)
            }

            // MARK: Vote-on-appeal sheet (carries AppealRouteContext)
            .ruulSheet(item: appealItem) { ctx in
                voteOnAppealSheet(ctx)
            }

            // MARK: Edit profile sheet
            .fullScreenCover(isPresented: boolBinding(for: .editProfile), onDismiss: {
                Task { await router.state.profileCoordinator?.refresh() }
            }) {
                if let pCoord = router.state.profileCoordinator {
                    EditProfileSheet(coordinator: pCoord)

                }
            }

            // MARK: Members list cover (read-only, everyone)
            .fullScreenCover(isPresented: boolBinding(for: .membersList)) {
                if let activeGroup = app.activeGroup, let uid = app.session?.user.id {
                    NavigationStack {
                        MembersListView(coordinator: MembersCoordinator(
                            group: activeGroup,
                            actorUserId: uid,
                            groupsRepo: app.groupsRepo
                        ))
                        .environment(app)
                    }
                }
            }

            // MARK: Members admin cover (admin actions)
            .fullScreenCover(isPresented: boolBinding(for: .membersAdmin)) {
                if let activeGroup = app.activeGroup, let uid = app.session?.user.id {
                    MembersAdminViewWrapper(group: activeGroup, uid: uid, app: app)
                }
            }

            // MARK: Create-vote picker sheet
            .fullScreenCover(isPresented: boolBinding(for: .createVotePicker)) {
                CreateVoteSheet(
                    onPickGeneralProposal: { router.present(.createGeneralProposal) },
                    onPickRuleChange: { router.present(.createRuleChange(nil)) },
                    onPickMemberRemoval: { router.present(.createMemberRemoval) }
                )

            }

            // MARK: Create general proposal sheet
            .fullScreenCover(isPresented: boolBinding(for: .createGeneralProposal), onDismiss: {
                Task {
                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                    async let i: Void? = router.state.inboxCoordinator?.refresh()
                    _ = await (r, i)
                }
            }) {
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
                                async let i: Void? = router.state.inboxCoordinator?.refresh()
                                _ = await (r, i)
                            }
                        }
                    )

                }
            }

            // MARK: Create rule-change sheet (carries optional GroupRule)
            .fullScreenCover(item: createRuleChangeItem, onDismiss: {
                Task {
                    async let r: Void? = router.state.rulesCoordinator?.refresh()
                    async let i: Void? = router.state.inboxCoordinator?.refresh()
                    _ = await (r, i)
                }
            }) { wrapper in
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
                                async let i: Void? = router.state.inboxCoordinator?.refresh()
                                _ = await (r, i)
                            }
                        }
                    )

                }
                let _ = wrapper // silence unused-variable warning; wrapper.rule available if needed
            }

            // MARK: Create member-removal sheet
            .fullScreenCover(isPresented: boolBinding(for: .createMemberRemoval), onDismiss: {
                Task {
                    async let i: Void? = router.state.inboxCoordinator?.refresh()
                    _ = await i
                }
            }) {
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

            // MARK: Navigation-push routes (no sheet presentation)
            // past, feed, groupHistory, acuerdos, sanciones, fineDetail,
            // voteDetail, openVotes are .navigationDestination pushes wired
            // inside per-tab NavigationStacks. No sheet branch needed here.
    }

    // MARK: - Screen builders

    @MainActor
    private func ruleEditSheet(_ ctx: RuleEditRouteContext) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let memberDirectory = router.state.memberDirectory
        let currentMember = memberDirectory[userId]?.member
            ?? fallbackMember(userId: userId, groupId: ctx.group.id)
        let editCoord = EditRulesCoordinator(
            group: ctx.group,
            currentMember: currentMember,
            actorUserId: userId,
            governance: app.governance,
            policyRepo: app.policyRepo,
            ruleRepo: app.ruleRepo,
            voteRepo: app.voteRepo,
            userActionRepo: app.userActionRepo
        )
        return NavigationStack {
            EditRuleSheet(
                rule: ctx.rule,
                pending: nil,
                prefilledAmount: ctx.proposedAmount,
                pendingActionId: ctx.pendingActionId,
                coordinator: editCoord,
                onDismiss: {
                    while router.state.activeRoutes.contains(where: { if case .ruleEdit = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            )
        }
    }

    @MainActor
    private func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let userId = app.session?.user.id ?? UUID()
        let memberDirectory = router.state.memberDirectory
        let calendarService = router.state.calendarService
        return AnyView(
            EventDetailHost(
                event: event,
                group: group,
                currentUserId: userId,
                memberDirectory: memberDirectory,
                calendarService: calendarService,
                onClose: {
                    router.state.activeEvent = nil
                    while router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                },
                onEditEvent: { editEvent in
                    router.state.activeEditEvent = editEvent
                    router.present(.editEvent)
                },
                onScannerOpen: { detail in
                    openScanner(for: detail)
                }
            )
        )
    }

    @MainActor @ViewBuilder
    private func eventEditScreen(_ event: Event) -> some View {
        if let group = app.groups.first(where: { $0.id == event.groupId }) {
            let editCoord = ResourceEditCoordinator(
                event: event,
                group: group,
                eventRepo: app.eventRepo,
                analytics: EventAnalytics(analytics: app.analytics)
            )
            EditEventView(coordinator: editCoord)
                .onChange(of: editCoord.updatedEvent) { _, newValue in
                    guard newValue != nil else { return }
                    Task {
                        await router.state.homeCoordinator?.refresh(force: true)
                        if let updated = newValue {
                            router.state.activeEvent = updated
                        }
                    }
                }
        }
    }

    @MainActor @ViewBuilder
    private func voteOnAppealSheet(_ ctx: AppealRouteContext) -> some View {
        let memberDirectory = router.state.memberDirectory
        let appellantName: String = {
            if let entry = memberDirectory.values.first(where: { $0.member.id == ctx.appeal.appellantMemberId }) {
                return entry.displayName
            }
            return "Un miembro"
        }()
        VoteOnAppealSheet(
            isPresented: appealPresentedBinding,
            fine: ctx.fine,
            appeal: ctx.appeal,
            appellantName: appellantName,
            voteCounts: nil
        ) { choice in
            Task {
                try? await app.appealRepo.castVote(appealId: ctx.appeal.id, choice: choice)
                await router.state.inboxCoordinator?.refresh()
            }
        }
    }

    // MARK: - Helpers

    private func openScanner(for detail: EventDetailCoordinator) {
        let confirmed = detail.rsvps.filter { $0.status == .going }
        let alreadyChecked = confirmed.filter { $0.isCheckedIn }.count
        let scanner = QRScannerService()
        let coord = CheckInScannerCoordinator(
            event: detail.event,
            totalConfirmed: confirmed.count,
            alreadyCheckedCount: alreadyChecked,
            scanner: scanner,
            checkInRepo: app.checkInRepo,
            analytics: EventAnalytics(analytics: app.analytics),
            memberLookup: { [memberDirectory = router.state.memberDirectory] id in
                memberDirectory[id]?.displayName ?? "Miembro"
            }
        )
        router.state.activeScannerCoordinator = coord
        router.present(.scanner(detail.event.id))
    }

    private func currentGroupMember(in group: RuulCore.Group) -> Member? {
        guard let userId = app.session?.user.id else { return nil }
        return router.state.memberDirectory[userId]?.member
    }

    private func fallbackMember(userId: UUID, groupId: UUID) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            role: "member",
            roles: [.member],
            active: false,
            joinedAt: .now
        )
    }

    private func nextDefaultDate(for group: RuulCore.Group) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(
            bySettingHour: 20, minute: 30, second: 0, of: tomorrow
        ) ?? tomorrow
    }

    // MARK: - Binding helpers

    private func boolBinding(for route: RootRoute) -> Binding<Bool> {
        Binding(
            get: { router.state.contains(route) },
            set: { wantsPresent in
                if wantsPresent {
                    if !router.state.contains(route) { router.present(route) }
                } else {
                    while router.state.contains(route) { router.state.dismissTop() }
                }
            }
        )
    }

    private func itemBinding<Payload: Hashable>(
        extract: @escaping (RootRoute) -> Payload?,
        matches: @escaping (RootRoute) -> Bool
    ) -> Binding<Payload?> {
        Binding(
            get: { router.state.activeRoutes.compactMap(extract).last },
            set: { newValue in
                if newValue == nil {
                    while router.state.activeRoutes.contains(where: matches) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    // MARK: - Per-case item bindings

    private var ruleEditItem: Binding<RuleEditRouteContext?> {
        itemBinding(
            extract: { route in
                if case .ruleEdit(let ctx) = route { return ctx } else { return nil }
            },
            matches: { route in
                if case .ruleEdit = route { return true } else { return false }
            }
        )
    }

    private var appealItem: Binding<AppealRouteContext?> {
        itemBinding(
            extract: { route in
                if case .voteOnAppeal(let ctx) = route { return ctx } else { return nil }
            },
            matches: { route in
                if case .voteOnAppeal = route { return true } else { return false }
            }
        )
    }

    /// Binding that drives the event detail cover via `state.activeEvent`.
    /// Using an `IdentifiableEventWrapper` so `fullScreenCover(item:)` can
    /// detect identity changes when a different event is opened.
    private var activeEventItem: Binding<IdentifiableEventWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }),
                      let event = router.state.activeEvent else { return nil }
                return IdentifiableEventWrapper(event: event)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeEvent = nil
                    while router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    private var activeEditEventItem: Binding<IdentifiableEventWrapper?> {
        Binding(
            get: {
                guard router.state.contains(.editEvent),
                      let event = router.state.activeEditEvent else { return nil }
                return IdentifiableEventWrapper(event: event)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeEditEvent = nil
                    while router.state.contains(.editEvent) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    private var activeScannerItem: Binding<IdentifiableScannerWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: { if case .scanner = $0 { return true }; return false }),
                      let coord = router.state.activeScannerCoordinator else { return nil }
                return IdentifiableScannerWrapper(coordinator: coord)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeScannerCoordinator = nil
                    while router.state.activeRoutes.contains(where: { if case .scanner = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    /// Binding for the appeal presented state (used by `VoteOnAppealSheet`
    /// which takes a `Binding<Bool>` rather than `item:`).
    private var appealPresentedBinding: Binding<Bool> {
        Binding(
            get: { router.state.activeRoutes.contains(where: { if case .voteOnAppeal = $0 { return true }; return false }) },
            set: { isPresented in
                if !isPresented {
                    while router.state.activeRoutes.contains(where: { if case .voteOnAppeal = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    /// Item binding for `.createRuleChange(GroupRule?)`. Wraps the optional
    /// rule in an `IdentifiableRuleChangeWrapper` so `sheet(item:)` works.
    private var createRuleChangeItem: Binding<IdentifiableRuleChangeWrapper?> {
        Binding(
            get: {
                guard let match = router.state.activeRoutes.last(where: { if case .createRuleChange = $0 { return true }; return false }) else { return nil }
                if case .createRuleChange(let rule) = match {
                    return IdentifiableRuleChangeWrapper(rule: rule)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    while router.state.activeRoutes.contains(where: { if case .createRuleChange = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }
}

// MARK: - GroupHomeSheetContent

@MainActor
private struct GroupHomeSheetContent: View {
    let group: RuulCore.Group
    let app: AppState
    let router: RootRouter

    @State private var path = NavigationPath()
    @State private var showEditIdentity = false
    @State private var showRotateCode = false
    @State private var showInvite = false
    @State private var showLeave = false
    @State private var showMembersAdminInvite = false

    private enum GroupNav: Hashable {
        case modules, currency, timezone, governance, rulePresets,
             membersList, membersAdmin
    }

    var body: some View {
        let coord = GroupHomeCoordinator(groupId: group.id, groupsRepo: app.groupsRepo)
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
                onConfirmLeave: { showLeave = true }
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
                }
            }
            .fullScreenCover(isPresented: $showMembersAdminInvite) {
                InviteMembersFromGroupView(group: group)
                    .environment(app)
            }
            .fullScreenCover(isPresented: $showEditIdentity) {
                EditGroupIdentitySheet(groupId: group.id)
                    .environment(app)
            }
            .fullScreenCover(isPresented: $showRotateCode) {
                RegenerateInviteCodeSheet(groupId: group.id)
                    .environment(app)
            }
            .fullScreenCover(isPresented: $showInvite) {
                InviteMembersFromGroupView(group: group)
                    .environment(app)
            }
            .fullScreenCover(isPresented: $showLeave) {
                LeaveGroupConfirmationSheet(group: group)
                    .environment(app)
            }
        }
        .environment(app)
    }
}

// MARK: - Private wrapper types

/// Wraps `Event` in an `Identifiable` struct so `fullScreenCover(item:)`
/// can track it. Identity is the event's UUID.
private struct IdentifiableEventWrapper: Identifiable, Hashable {
    let event: Event
    var id: UUID { event.id }
}

/// Wraps `CheckInScannerCoordinator` (which is a class) in a struct that is
/// both `Identifiable` and `Hashable`. Identity is the event UUID.
private struct IdentifiableScannerWrapper: Identifiable, Hashable {
    let coordinator: CheckInScannerCoordinator
    var id: UUID { coordinator.event.id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Wraps the optional `GroupRule?` payload of `.createRuleChange` so
/// `sheet(item:)` has an `Identifiable` handle. Uses a stable UUID so
/// SwiftUI treats each presentation as a distinct sheet.
private struct IdentifiableRuleChangeWrapper: Identifiable, Hashable {
    let rule: GroupRule?
    let id: UUID = UUID()
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rule?.id == rhs.rule?.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(rule?.id) }
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
        }
    }
}

// MARK: - View extension

public extension View {
    func rootShellSheets(router: RootRouter) -> some View {
        modifier(RootShellSheets(router: router))
    }
}
