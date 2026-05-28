import SwiftUI
import RuulCore

/// D2 + D3 — Per-group tab bar shell. The app's root surface when the
/// caller has at least one group. Five tabs mirror the doctrine in
/// `Plans/Active/UIBottomUpPlan.md` §0:
///
///     🏠 Inicio · 💰 Dinero · 📦 Recursos · 👥 Miembros · ⚙️ Ajustes
///
/// Top-left toolbar slot hosts the group switcher (Calendar/Reminders
/// pattern). Top-right hosts the avatar — opens `PersonalProfileSheet`.
/// Each tab is its own `NavigationStack` so pushes inside a tab don't
/// dismiss the tab bar.
public struct GroupTabsHost: View {
    let container: DependencyContainer
    let group: GroupListItem
    let onSelectGroup: (GroupListItem) -> Void

    @State private var selectedTab: GroupTab = .home
    @State private var isShowingSwitcher: Bool = false
    @State private var isShowingPersonalProfile: Bool = false
    /// Drives the `MemberDetailView` push from the Members tab. Mirrors
    /// the pattern used by `GroupHomeView`.
    @State private var pendingMemberSelection: MembershipBoundaryItem?

    public init(
        container: DependencyContainer,
        group: GroupListItem,
        onSelectGroup: @escaping (GroupListItem) -> Void
    ) {
        self.container = container
        self.group = group
        self.onSelectGroup = onSelectGroup
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
            moneyTab
            resourcesTab
            membersTab
            settingsTab
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
    }

    // MARK: - Tabs

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            GroupHomeView(container: container, group: group)
                // Switcher button already shows the group name; drop
                // the redundant inline title from GroupHomeView.
                .navigationTitle("")
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
    private var resourcesTab: some View {
        NavigationStack {
            ResourcesListView(store: container.resourcesStore, groupId: group.id)
                .toolbar { shellToolbar }
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
                    memberItem: item
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
    private var settingsTab: some View {
        NavigationStack {
            GroupSettingsView(container: container, group: group)
                .toolbar { shellToolbar }
        }
        .tabItem {
            Label(L10n.GroupTabs.settings, systemImage: "gearshape")
        }
        .tag(GroupTab.settings)
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

    private enum GroupTab: Hashable {
        case home, money, resources, members, settings
    }
}
