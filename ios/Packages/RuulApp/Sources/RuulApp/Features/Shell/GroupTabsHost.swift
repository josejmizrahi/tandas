import SwiftUI
import RuulCore

/// D2 + D3 — Per-group tab bar shell. The app's root surface when the
/// caller has at least one group. Four tabs, one verb each:
///
///     🏠 Inicio · 💰 Dinero · 👥 Personas · 🗂️ El grupo
///
/// "Recursos" no longer earns a dedicated tab: at Foundation level it's
/// 0-3 items that rarely change, so it lives as a section inside
/// "El grupo" alongside the rest of the non-feed, non-money, non-people
/// primitives.
///
/// Top-left toolbar slot hosts the group switcher (Calendar/Reminders
/// pattern). Top-right hosts the avatar — opens `PersonalProfileSheet`.
/// Each tab is its own `NavigationStack` so pushes inside a tab don't
/// dismiss the tab bar.
public struct GroupTabsHost: View {
    let container: DependencyContainer
    let group: GroupListItem
    let onSelectGroup: (GroupListItem) -> Void
    /// R.0H.4 — when the host was entered from `PersonalHomeView`
    /// (flag-ON branch), the shell injects a back-to-My-World callback.
    /// `nil` in the v1 flag-OFF path leaves the toolbar unchanged.
    let onBackToPersonalHome: (() -> Void)?

    /// Hoisted to the shell so deep-link arrivals (V3-A4) can request
    /// focus on a specific tab (`.money`, `.members`, `.group`) before
    /// the user even touches the bar.
    @Binding var selectedTab: GroupTab

    @State private var isShowingSwitcher: Bool = false
    @State private var isShowingPersonalProfile: Bool = false
    @State private var isShowingInbox: Bool = false
    /// D.22 — Search MVP sheet. Mirrors the Inbox bell wiring.
    @State private var isShowingSearch: Bool = false
    /// Drives the `MemberDetailView` push from the Personas tab.
    @State private var pendingMemberSelection: MembershipBoundaryItem?

    public init(
        container: DependencyContainer,
        group: GroupListItem,
        selectedTab: Binding<GroupTab>,
        onSelectGroup: @escaping (GroupListItem) -> Void,
        onBackToPersonalHome: (() -> Void)? = nil
    ) {
        self.container = container
        self.group = group
        self._selectedTab = selectedTab
        self.onSelectGroup = onSelectGroup
        self.onBackToPersonalHome = onBackToPersonalHome
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
            moneyTab
            membersTab
            groupTab
        }
        .sheet(isPresented: $isShowingSwitcher) {
            GroupSwitcherSheet(
                container: container,
                currentGroupId: group.id,
                onSelect: onSelectGroup
            )
        }
        .sheet(isPresented: $isShowingPersonalProfile) {
            PersonalProfileSheet(container: container)
        }
        .sheet(isPresented: $isShowingInbox) {
            NavigationStack {
                InboxView(store: container.inboxStore, scopeGroupId: group.id)
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            SearchView(store: container.searchStore) { result in
                handleSearchSelection(result)
            }
        }
        // D.22 — bind the search store to the active group on enter and
        // reset on group switch so a stale query from group A doesn't
        // leak into group B.
        .task(id: group.id) {
            container.searchStore.groupId = group.id
        }
        // D.21B — keep badge fresh when scope changes or app foregrounds
        .task(id: group.id) {
            await container.inboxStore.refreshBadge(groupId: group.id)
        }
        // V3-A1 — wire realtime listeners to the active group. The
        // `.task(id:)` lifecycle cancels-and-replaces on group switch
        // AND on sign-out (shell tears down `GroupTabsHost` when the
        // session drops). The trailing sleep keeps the task alive so
        // cancellation has a place to land — once cancelled, the loop
        // exits and the stores tear their subscriptions down.
        .task(id: group.id) {
            let realtime = container.realtime
            let events = container.eventsStore
            let disputes = container.disputesStore
            let decisions = container.decisionsStore

            await events.startListening(groupId: group.id, realtime: realtime)
            await disputes.startListening(groupId: group.id, realtime: realtime)
            await decisions.startListening(groupId: group.id, realtime: realtime)

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }

            await events.stopListening()
            await disputes.stopListening()
            await decisions.stopListening()
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            GroupHomeFeedView(container: container, group: group)
                .toolbar { shellToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.home, systemImage: "house")
        }
        .tag(GroupTab.home)
    }

    @ViewBuilder
    private var moneyTab: some View {
        NavigationStack {
            MoneyDashboardView(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            )
            .toolbar { shellToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.money, systemImage: "banknote")
        }
        .tag(GroupTab.money)
    }

    @ViewBuilder
    private var membersTab: some View {
        NavigationStack {
            MembersListView(
                store: container.membersStore,
                groupId: group.id,
                container: container,
                onSelectMember: { item in
                    pendingMemberSelection = item
                }
            )
            .navigationDestination(item: $pendingMemberSelection) { item in
                MemberDetailView(
                    sanctionsStore: container.sanctionsStore,
                    reputationStore: container.reputationStore,
                    moneyStore: container.moneyStore,
                    rolesStore: container.rolesStore,
                    membersStore: container.membersStore,
                    groupId: group.id,
                    memberItem: item,
                    activityFetcher: { gid, mid, limit in
                        try await container.rpcClient.groupEventsForMember(
                            groupId: gid,
                            membershipId: mid,
                            limit: limit
                        )
                    },
                    permissionsFetcher: { gid in
                        try await container.groupRepository.listMemberPermissions(
                            groupId: gid,
                            userId: nil
                        )
                    },
                    provenanceFetcher: { mid in
                        try await container.membersRepository.provenance(membershipId: mid)
                    },
                    quickActionStores: MemberDetailView.QuickActionStores(
                        mandates: container.mandatesStore,
                        reputationFeed: container.reputationFeedStore
                    ),
                    decisionsStore: container.decisionsStore,
                    decisionsRepository: container.decisionsRepository
                )
            }
            .toolbar { shellToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.members, systemImage: "person.3")
        }
        .tag(GroupTab.members)
    }

    @ViewBuilder
    private var groupTab: some View {
        NavigationStack {
            GroupSettingsView(container: container, group: group)
                .toolbar { shellToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.group, systemImage: "rectangle.stack")
        }
        .tag(GroupTab.group)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        // R.0H.4 — extra leading affordance to return to "Mi mundo"
        // when the host was entered via `PersonalHomeView`. Coexists
        // with the existing group-switcher chevron so the user can
        // still hop between groups without going up a level.
        if let onBack = onBackToPersonalHome {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onBack()
                } label: {
                    Label("Mi mundo", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel(Text("Volver a Mi mundo"))
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingSwitcher = true
            } label: {
                HStack(spacing: 4) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel(Text(L10n.GroupSwitcher.title))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingInbox = true
            } label: {
                Label("Bandeja", systemImage: "tray.fill")
                    .labelStyle(.iconOnly)
            }
            .badge(container.inboxStore.unreadCount)
            .accessibilityLabel(
                Text(container.inboxStore.unreadCount > 0
                     ? "Bandeja (\(container.inboxStore.unreadCount) sin leer)"
                     : "Bandeja")
            )
        }
        // D.22 — lupa between bell and avatar. Same wiring pattern as
        // the Inbox bell (toggles @State + presents sheet).
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingSearch = true
            } label: {
                Label("Buscar", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(Text("Buscar"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingPersonalProfile = true
            } label: {
                Label(L10n.PersonalProfile.title, systemImage: "person.crop.circle")
                    .labelStyle(.iconOnly)
            }
        }
    }

    // MARK: - D.22 — Search result routing

    /// Receives the tapped `SearchResult` from `SearchView`, dismisses
    /// the sheet, and routes by entity type. Members + decisions reuse
    /// the existing `DeepLinkRouter` path (full nav to detail). Resources
    /// + rules fall back to a tab-switch (lands the user on Group tab
    /// where the relevant list lives) since V1 doesn't extend `DeepLink`
    /// with resource/rule cases. Search clears on dismiss.
    private func handleSearchSelection(_ result: SearchResult) {
        let router = container.deepLinkRouter
        switch result.entityType {
        case .member:
            router.apply(.member(groupId: result.groupId, membershipId: result.entityId))
        case .decision:
            router.apply(.decision(groupId: result.groupId, decisionId: result.entityId))
        case .resource, .rule:
            selectedTab = .group
        }
        isShowingSearch = false
        container.searchStore.clear()
    }
}

/// Four canonical tabs in `GroupTabsHost`. `public` so the shell can
/// hoist `selectedTab` as a `Binding` and drive focus from deep-link
/// arrivals (V3-A4).
public enum GroupTab: Hashable, Sendable {
    case home, money, members, group
}
