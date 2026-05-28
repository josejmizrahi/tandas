import SwiftUI
import RuulCore

/// First authenticated screen of the Foundation shell — the caller's
/// groups. Renders the list, hosts "Nuevo grupo" + "Tengo código" +
/// "Cerrar sesión", and refreshes via `GroupsStore.refresh()`. Row taps
/// push `GroupHomeView` onto the navigation stack.
struct GroupListView: View {
    let container: DependencyContainer

    @State private var isShowingCreateSheet: Bool = false
    @State private var isShowingAcceptSheet: Bool = false
    @State private var isShowingPersonalProfile: Bool = false

    var body: some View {
        List {
            if container.profileStore.requiresProfileCompletion {
                Section {
                    ProfileOnboardingNudge(store: container.profileStore)
                }
            }

            switch container.groupsStore.phase {
            case .idle, .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 24)
                        Spacer()
                    }
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label("No pudimos cargar tus grupos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reintentar") {
                            Task { await container.groupsStore.refresh() }
                        }
                    }
                }
            case .loaded:
                if container.groupsStore.groups.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.3")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Aún no tienes grupos")
                                .font(.headline)
                            Text("Crea uno nuevo para empezar a coordinar con tu gente.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Crear grupo") {
                                isShowingCreateSheet = true
                            }
                            .buttonStyle(.glassProminent)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section {
                        ForEach(container.groupsStore.groups) { group in
                            NavigationLink(value: group) {
                                GroupRow(group: group)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Mis grupos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: GroupListItem.self) { group in
            GroupTabsHost(container: container, group: group)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        Label("Crear grupo", systemImage: "plus")
                    }
                    Button {
                        isShowingAcceptSheet = true
                    } label: {
                        Label("Tengo un código", systemImage: "ticket")
                    }
                } label: {
                    Label("Agregar", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingPersonalProfile = true
                } label: {
                    Label(L10n.PersonalProfile.title, systemImage: "person.crop.circle")
                }
            }
        }
        .refreshable {
            await container.groupsStore.refresh()
        }
        .task {
            await container.groupsStore.refresh()
            await container.profileStore.refreshIfNeeded()
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateGroupView(container: container) {
                isShowingCreateSheet = false
                Task { await container.groupsStore.refresh() }
            }
        }
        .sheet(isPresented: $isShowingAcceptSheet) {
            AcceptInviteSheet(container: container) { _ in
                isShowingAcceptSheet = false
                Task { await container.groupsStore.refresh() }
            }
        }
        .sheet(isPresented: profileSheetBinding) {
            EditProfileView(
                store: container.profileStore,
                mode: container.profileStore.requiresProfileCompletion ? .onboarding : .edit
            )
        }
        .sheet(isPresented: $isShowingPersonalProfile) {
            PersonalProfileSheet(container: container)
        }
    }

    /// Bridges the `@Bindable`-style flag on `ProfileStore` to the
    /// `.sheet(isPresented:)` API the existing View hierarchy uses. The
    /// store owns the boolean so the nudge + the account menu push into
    /// the same sheet without colliding state.
    private var profileSheetBinding: Binding<Bool> {
        Binding(
            get: { container.profileStore.isEditPresented },
            set: { container.profileStore.isEditPresented = $0 }
        )
    }
}

private struct GroupRow: View {
    let group: GroupListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.headline)
            if let summary = group.purposeSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let category = group.category, !category.isEmpty {
                Text(category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
