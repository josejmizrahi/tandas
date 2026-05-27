import SwiftUI
import RuulCore

/// Members surface for a single group. Designed to be embedded inside
/// a parent `NavigationStack` (slice 7 will mount it from a tab); the
/// view itself only provides the `List`, toolbar item, search field,
/// refresh handler, and sheet presenter so it composes cleanly inside
/// any container.
///
/// Renders placeholder rows during the initial load, a search-empty
/// state when the query has no matches, and the canonical empty /
/// error placeholders for the no-data and failure paths.
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
            if store.members.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    MemberRowView(member: .placeholder)
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
            if store.filteredMembers.isEmpty {
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
                ForEach(section.members) { member in
                    MemberRowView(member: member)
                }
            } header: {
                Text(section.kind.title)
            }
        }
    }
}

#Preview("Populated") {
    @Previewable @State var store = MembersStore(initialMembers: MembersPreviewData.all)
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

#Preview("Dark mode") {
    @Previewable @State var store = MembersStore(initialMembers: MembersPreviewData.all)
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
    .preferredColorScheme(.dark)
}

#Preview("xxxLarge Dynamic Type") {
    @Previewable @State var store = MembersStore(initialMembers: MembersPreviewData.all)
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
