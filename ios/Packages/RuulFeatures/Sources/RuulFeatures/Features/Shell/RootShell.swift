import SwiftUI
import RuulCore
import RuulUI

/// Post-auth root view. iOS 26 native TabView + Liquid Glass tab bar via
/// `tabBarMinimizeBehavior(.onScrollDown)`. Presentation soup lives in
/// `RootShellSheets` (570 L); navigation intent flows through `RootRouter`.
///
/// Pass 1 preserves the legacy 5-tab inventory exactly. Pass 2 changes
/// the inventory to match AppShell.md.
@MainActor
public struct RootShell: View {
    @Environment(AppState.self) private var app

    @State private var shellState: RootShellState
    @State private var router: RootRouter

    // Coordinator state — built/rebuilt whenever the active group changes.
    @State private var homeCoordinator: HomeCoordinator?
    @State private var inboxCoordinator: InboxCoordinator?
    @State private var rulesCoordinator: RulesCoordinator?
    @State private var profileCoordinator: ProfileCoordinator?
    @State private var myFinesCoordinator: MyFinesCoordinator?
    @State private var activityCoordinator: ActivityCoordinator?

    /// Per-group member directory cache — mirrors MainTabView.memberDirectory.
    @State private var memberDirectory: [UUID: MemberWithProfile] = [:]

    public init() {
        let state = RootShellState()
        _shellState = State(initialValue: state)
        _router = State(initialValue: RootRouter(state: state))
    }

    public var body: some View {
        TabView(selection: tabBinding) {
            HomeTab(
                home: homeCoordinator,
                inbox: inboxCoordinator
            )
            .tabItem { Label("Inicio", systemImage: "house.fill") }
            .tag(RootTab.home)

            InboxTab(inbox: inboxCoordinator)
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .tag(RootTab.inbox)
                .badge(inboxCoordinator?.actions.count ?? 0)

            CreateTabIntercept()
                .tabItem { Label("Crear", systemImage: "plus.circle.fill") }
                .tag(RootTab.create)

            ActivityTab(activity: activityCoordinator)
                .tabItem { Label("Actividad", systemImage: "clock.arrow.circlepath") }
                .tag(RootTab.activity)

            ProfileTab(profile: profileCoordinator, myFines: myFinesCoordinator)
                .tabItem { Label("Perfil", systemImage: "person.crop.circle.fill") }
                .tag(RootTab.profile)
        }
        .tint(Color.ruulAccent)
        .tabBarMinimizeBehavior(.onScrollDown)
        .animation(.ruulGroupSwitch, value: app.activeGroupId)
        .environment(router)
        .modifier(RootShellSheets(router: router))
        .task { await rebuildCoordinators() }
        .task(id: app.activeGroupId) { await rebuildCoordinators() }
        .onChange(of: app.pendingEventDeepLink) { _, link in
            guard let link else { return }
            router.handle(eventDeepLink: link)
            app.consumeEventDeepLink()
        }
        .onChange(of: app.pendingRuleChangeDeepLink) { _, link in
            guard let link else { return }
            Task { await handleRuleChangeDeepLink(link) }
        }
        .environment(\.locale, Locale(identifier: app.profile?.locale ?? "es-MX"))
    }

    // MARK: - Tab selection

    private var tabBinding: Binding<RootTab> {
        Binding(
            get: { shellState.selectedTab },
            set: { tab in
                router.handleTabSelection(tab, hasActiveGroup: app.activeGroup != nil)
            }
        )
    }

    // MARK: - Coordinator construction

    /// Mirrors MainTabView.rebuildCoordinators(for:) verbatim. Assigns each
    /// coordinator to both the local @State and the matching shellState field
    /// so RootShellSheets can read them (L68, L76-82, L103-110, L131-140).
    private func rebuildCoordinators() async {
        guard let group = app.activeGroup, let session = app.session else { return }
        let userId = session.user.id

        homeCoordinator = HomeCoordinator(
            group: group,
            allGroups: app.groups,
            userId: userId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            resourceRepo: app.resourceRepo
        )
        shellState.homeCoordinator = homeCoordinator

        inboxCoordinator = InboxCoordinator(
            userId: userId,
            groupId: nil,                   // 14.2 — cross-group inbox
            userActionRepo: app.userActionRepo,
            groupsRepo: app.groupsRepo,
            changeFeed: app.multiDeviceChangeFeed,
            analytics: app.analytics
        )
        shellState.inboxCoordinator = inboxCoordinator

        myFinesCoordinator = MyFinesCoordinator(
            userId: userId,
            fineRepo: app.fineRepo,
            groupsRepo: app.groupsRepo,
            changeFeed: app.multiDeviceChangeFeed
        )
        shellState.myFinesCoordinator = myFinesCoordinator

        profileCoordinator = ProfileCoordinator(
            userId: userId,
            profileRepo: app.profileRepo
        )
        shellState.profileCoordinator = profileCoordinator

        // Load member directory before RulesCoordinator so we can hand it
        // the current actor's Member row for the governance check.
        await refreshMemberDirectory(for: group.id)
        let currentMember = memberDirectory[userId]?.member
            ?? Self.fallbackMember(userId: userId, groupId: group.id)
        rulesCoordinator = RulesCoordinator(
            group: group,
            currentMember: currentMember,
            governance: app.governance,
            ruleRepo: app.ruleRepo,
            voteRepo: app.voteRepo
        )
        shellState.rulesCoordinator = rulesCoordinator

        // Fase 4b: activity es tab top-level. Construimos su coordinator en el
        // mismo rebuild para que el cambio de grupo refresque el filtro.
        activityCoordinator = ActivityCoordinator(
            groupId: group.id,
            repo: app.systemEventRepo,
            // Slice 11: pass groupsRepo so the feed can render actor
            // names ("Jose creó un derecho") instead of "Alguien".
            groupsRepo: app.groupsRepo
        )
        shellState.activityCoordinator = activityCoordinator

        // Fire initial refreshes for non-Home coordinators that don't have
        // their own `.task { refresh() }` on view appear.
        await inboxCoordinator?.refresh()
    }

    /// Synthetic inactive member used when the directory hasn't surfaced
    /// the current user yet (anon sessions, just-joined races). Forces the
    /// fail-closed governance gate to deny — the pencil stays hidden until
    /// the next directory refresh promotes the row.
    private static func fallbackMember(userId: UUID, groupId: UUID) -> Member {
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

    /// Fetch member+profile pairs once and cache by userId.
    @MainActor
    private func refreshMemberDirectory(for groupId: UUID) async {
        guard let rows = try? await app.groupsRepo.membersWithProfiles(of: groupId) else { return }
        var directory: [UUID: MemberWithProfile] = [:]
        for row in rows {
            directory[row.member.userId] = row
        }
        memberDirectory = directory
    }

    // MARK: - Deep link handling

    /// Mirrors MainTabView.handleRuleChangeDeepLink verbatim. Fetches the rule
    /// from the repo, switches active group if needed, then routes via
    /// RootRouter.handleRuleChange so the sheet presenter in RootShellSheets
    /// fires.
    private func handleRuleChangeDeepLink(_ link: RuleChangeDeepLink) async {
        defer { app.consumeRuleChangeDeepLink() }

        for group in app.groups {
            guard let rules = try? await app.ruleRepo.list(groupId: group.id),
                  let rule = rules.first(where: { $0.id == link.ruleId })
            else { continue }

            // Switch active group if this rule lives elsewhere.
            if app.activeGroup?.id != group.id {
                app.activeGroupId = group.id
            }
            router.handleRuleChange(
                rule: rule,
                group: group,
                proposedAmount: link.proposedAmount,
                pendingActionId: nil
            )
            return
        }
    }
}

