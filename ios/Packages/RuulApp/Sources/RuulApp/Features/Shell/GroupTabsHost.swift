import SwiftUI
import RuulCore

/// D2 — Per-group tab bar shell. Replaces the previous direct push to
/// `GroupHomeView`. The five tabs mirror the doctrine in
/// `Plans/Active/UIBottomUpPlan.md` §0:
///
///     🏠 Inicio · 💰 Dinero · 📦 Recursos · 👥 Miembros · ⚙️ Ajustes
///
/// Each tab hosts its own `NavigationStack` so pushes from inside a
/// tab don't dismiss the tab bar. The outer NavigationStack from
/// `RuulAppShell` still owns the "Mis grupos" affordance — we hide the
/// outer nav bar here and surface it as a leading toolbar button in
/// the Inicio tab to avoid stacked navigation bars.
///
/// `GroupHomeView` is reused as the Inicio tab content for V1; the
/// situational `GroupHomeFeedView` (5 clusters per
/// `doctrine_group_space_situational`) lands in a later slice.
public struct GroupTabsHost: View {
    let container: DependencyContainer
    let group: GroupListItem

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: GroupTab = .home

    public init(container: DependencyContainer, group: GroupListItem) {
        self.container = container
        self.group = group
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
            moneyTab
            resourcesTab
            membersTab
            settingsTab
        }
        // Outer NavigationStack (RuulAppShell) hosts this view; hide
        // its nav bar so the inner tabs render with a single nav bar
        // each. Back-to-Mis-grupos lives as a toolbar button in
        // every tab (see `backToGroupsToolbar`).
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            GroupHomeView(container: container, group: group)
                .toolbar { backToGroupsToolbar }
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
            .toolbar { backToGroupsToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.money, systemImage: "banknote")
        }
        .tag(GroupTab.money)
    }

    @ViewBuilder
    private var resourcesTab: some View {
        NavigationStack {
            ResourcesListView(store: container.resourcesStore, groupId: group.id)
                .toolbar { backToGroupsToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.resources, systemImage: "square.stack.3d.up")
        }
        .tag(GroupTab.resources)
    }

    @ViewBuilder
    private var membersTab: some View {
        NavigationStack {
            MembersListView(
                store: container.membersStore,
                groupId: group.id,
                onSelectMember: nil
            )
            .toolbar { backToGroupsToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.members, systemImage: "person.3")
        }
        .tag(GroupTab.members)
    }

    @ViewBuilder
    private var settingsTab: some View {
        NavigationStack {
            GroupSettingsView(container: container, group: group)
                .toolbar { backToGroupsToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.settings, systemImage: "gearshape")
        }
        .tag(GroupTab.settings)
    }

    // MARK: - Helpers

    @ToolbarContentBuilder
    private var backToGroupsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label(L10n.GroupTabs.backToGroups, systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private enum GroupTab: Hashable {
        case home, money, resources, members, settings
    }
}
