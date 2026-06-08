import SwiftUI
import RuulCore

/// F.5 — lista de miembros del contexto.
public struct MembersListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: MembersStore
    @State private var isShowingInvite = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: MembersStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(context: context) }
                }

            case .loaded:
                membersList
            }
        }
        .navigationTitle("Miembros")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canInvite(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingInvite = true
                    } label: {
                        Label("Invitar", systemImage: "person.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingInvite) {
            InviteMembersView(context: context, store: store, container: container)
        }
    }

    @ViewBuilder
    private var membersList: some View {
        if store.members.isEmpty {
            EmptyStateView(
                symbolName: "person.2",
                title: "Sin miembros",
                message: "Invita a alguien con un código para empezar."
            )
        } else {
            List {
                Section {
                    ForEach(store.members) { member in
                        NavigationLink {
                            MemberDetailView(
                                member: member,
                                context: context,
                                store: store,
                                myActorId: container.currentActorStore.actorId,
                                container: container
                            )
                        } label: {
                            memberRow(member)
                        }
                    }
                } header: {
                    Text("\(store.members.count) miembro\(store.members.count == 1 ? "" : "s")")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ContextMember) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: member.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    if member.actorId == container.currentActorStore.actorId {
                        Text("(tú)")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                if let joined = member.joinedAt {
                    Text("Desde \(joined.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            Spacer()
            if member.isFounder {
                Text("Fundador")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
            } else if member.isAdmin {
                Text("Admin")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Tint.info)
            }
        }
    }
}

#Preview("Miembros") {
    NavigationStack {
        MembersListView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
