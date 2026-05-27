import SwiftUI
import RuulCore

/// Members surface for a single group. Renders boundary items
/// (memberships + pending invites) returned by
/// `group_membership_boundary`. Designed to be embedded inside a
/// parent `NavigationStack` (mounted from `GroupHomeView`).
public struct MembersListView: View {
    @Bindable var store: MembersStore
    let groupId: UUID

    public init(store: MembersStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Members.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $store.searchText, prompt: Text(L10n.Members.searchPrompt))
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.isInviteSheetPresented = true
                } label: {
                    Label(L10n.Members.inviteButton, systemImage: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $store.isInviteSheetPresented) {
            MembersInviteSheet(store: store, groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if store.items.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    MemberRowView(item: .placeholder)
                        .redacted(reason: .placeholder)
                }
            } else {
                loadedSections
            }
        case .failed(let message):
            MembersErrorStateView(message: message) {
                Task { await store.refresh(groupId: groupId) }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.filteredItems.isEmpty {
                if store.searchText.isEmpty {
                    MembersEmptyStateView()
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                        .listRowBackground(Color.clear)
                }
            } else {
                loadedSections
            }
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        ForEach(store.sections) { section in
            Section {
                ForEach(section.members) { item in
                    MemberRowView(item: item)
                }
            } header: {
                Text(section.kind.title)
            }
        }
    }
}

// MARK: - Preview placeholder

extension MembershipBoundaryItem {
    /// Stable redacted-placeholder shape for skeleton rows during the
    /// first load. SwiftUI swaps the literal glyphs for grey blocks.
    static var placeholder: MembershipBoundaryItem {
        MembershipBoundaryItem(
            id: UUID(),
            kind: .membership,
            displayName: "Placeholder Name",
            roleNames: ["Placeholder role"]
        )
    }
}

#Preview("Populated") {
    @Previewable @State var store = MembersStore(initialItems: MembersPreviewData.boundaryAll)
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Empty") {
    @Previewable @State var store: MembersStore = {
        let s = MembersStore()
        s.phase = .loaded
        return s
    }()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Loading") {
    @Previewable @State var store = MembersStore()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Failed") {
    @Previewable @State var store: MembersStore = {
        let s = MembersStore()
        s.phase = .failed(message: "Sin conexión. Vuelve a intentar.")
        return s
    }()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}
