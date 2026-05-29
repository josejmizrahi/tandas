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

    /// Hoisted to the shell so deep-link arrivals (V3-A4) can request
    /// focus on a specific tab (`.money`, `.members`, `.group`) before
    /// the user even touches the bar.
    @Binding var selectedTab: GroupTab

    @State private var isShowingSwitcher: Bool = false
    @State private var isShowingPersonalProfile: Bool = false
    /// Drives the `MemberDetailView` push from the Personas tab.
    @State private var pendingMemberSelection: MembershipBoundaryItem?

    public init(
        container: DependencyContainer,
        group: GroupListItem,
        selectedTab: Binding<GroupTab>,
        onSelectGroup: @escaping (GroupListItem) -> Void
    ) {
        self.container = container
        self.group = group
        self._selectedTab = selectedTab
        self.onSelectGroup = onSelectGroup
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
                    quickActionStores: MemberDetailView.QuickActionStores(
                        mandates: container.mandatesStore,
                        reputationFeed: container.reputationFeedStore
                    )
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
                isShowingPersonalProfile = true
            } label: {
                Label(L10n.PersonalProfile.title, systemImage: "person.crop.circle")
                    .labelStyle(.iconOnly)
            }
        }
    }

}

/// Four canonical tabs in `GroupTabsHost`. `public` so the shell can
/// hoist `selectedTab` as a `Binding` and drive focus from deep-link
/// arrivals (V3-A4).
public enum GroupTab: Hashable, Sendable {
    case home, money, members, group
}
