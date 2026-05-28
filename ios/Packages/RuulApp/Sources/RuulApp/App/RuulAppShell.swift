import SwiftUI
import RuulCore

/// Root view for the Foundation iOS surface. Branches on
/// `SessionStore.state`:
///
/// - `.bootstrapping` → small splash while AuthService loads its cached
///   session.
/// - `.signedOut` → `SignInWithOTPView`.
/// - `.signedIn` → `GroupTabsHost` for the currently-focused group
///   (D3 shell). When the caller has no groups, the welcome screen
///   surfaces Create + Accept inline. The list of groups lives only
///   in `GroupSwitcherSheet` from now on.
public struct RuulAppShell: View {
    @State private var container: DependencyContainer
    /// Locally-tracked selection so the switcher can change groups
    /// without async-store loops. Defaults to the first group when
    /// `nil`. Synced into `CurrentGroupStore` whenever it changes.
    @State private var currentGroupId: UUID?

    /// D4 — pending entity-scoped destination opened from a deep link.
    /// Drives a sheet at the shell level so detail surfaces don't have
    /// to live inside the normal tab-NavigationStack hierarchy when the
    /// app is cold-launched into them.
    @State private var pendingDecision: PendingDecision?

    public init(container: DependencyContainer = DependencyContainer()) {
        _container = State(initialValue: container)
    }

    public var body: some View {
        content
            .task {
                container.bootstrap()
            }
            .onOpenURL { url in
                container.deepLinkRouter.handle(url)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch container.sessionStore.state {
        case .bootstrapping:
            BootstrappingView()
        case .signedOut:
            SignInWithOTPView(container: container)
        case .signedIn:
            signedInContent
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        let groups = container.groupsStore.groups
        let resolved = resolveCurrentGroup(from: groups)

        Group {
            switch container.groupsStore.phase {
            case .idle, .loading:
                if let group = resolved {
                    // Show the shell against the previously-loaded
                    // group while a refresh runs in the background.
                    shellFor(group)
                } else {
                    BootstrappingView()
                }
            case .failed(let message):
                ErrorBanner(message: message) {
                    Task { await container.groupsStore.refresh() }
                }
            case .loaded:
                if let group = resolved {
                    shellFor(group)
                } else {
                    WelcomeNoGroupsView(container: container) {
                        Task { await container.groupsStore.refresh() }
                    }
                }
            }
        }
        // The previous shell relied on `GroupListView.task` to kick
        // off the first `groupsStore.refresh()`. Now that the list is
        // gone, we own that fetch here — otherwise signed-in users
        // hang on `BootstrappingView` forever.
        .task {
            await container.groupsStore.refresh()
            await container.profileStore.refreshIfNeeded()
        }
        // D4 — try to apply a pending deep link whenever it changes
        // OR whenever the groups list resolves (a cold-launched link
        // arrives before the groups query completes).
        .onChange(of: container.deepLinkRouter.pending) { _, _ in
            applyPendingDeepLink()
        }
        .onChange(of: container.groupsStore.groups) { _, _ in
            applyPendingDeepLink()
        }
        .sheet(item: $pendingDecision) { pending in
            NavigationStack {
                DecisionDetailView(
                    store: container.decisionsStore,
                    groupId: pending.groupId,
                    decisionId: pending.decisionId,
                    initial: GroupDecisionSummary(
                        id: pending.decisionId,
                        groupId: pending.groupId,
                        title: String(localized: L10n.Decisions.title)
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { pendingDecision = nil }
                    }
                }
            }
        }
    }

    /// Resolves the current `DeepLinkRouter.pending` link against the
    /// loaded groups list and applies it: switches the focused group,
    /// then triggers any entity-specific destination (e.g. the
    /// decision sheet). Silently no-ops if the target group isn't in
    /// the caller's list — we'd rather drop unreachable links than
    /// flash an error.
    private func applyPendingDeepLink() {
        guard let link = container.deepLinkRouter.pending else { return }
        let groups = container.groupsStore.groups
        guard let target = groups.first(where: { $0.id == link.groupId }) else {
            // Groups still loading — leave `pending` set so the next
            // `onChange(of: groups)` can retry. If the user really
            // isn't a member, the link will never resolve and stays
            // buffered until the next launch.
            return
        }
        if currentGroupId != target.id {
            currentGroupId = target.id
            Task { await container.currentGroupStore.setGroup(target) }
        }
        switch link {
        case .group:
            break
        case .decision(let groupId, let decisionId):
            pendingDecision = PendingDecision(groupId: groupId, decisionId: decisionId)
        }
        container.deepLinkRouter.consume()
    }

    /// `Identifiable` wrapper around the IDs so `.sheet(item:)` can key
    /// off the destination directly instead of needing a separate bool.
    private struct PendingDecision: Identifiable, Equatable {
        let groupId: UUID
        let decisionId: UUID
        var id: UUID { decisionId }
    }

    @ViewBuilder
    private func shellFor(_ group: GroupListItem) -> some View {
        // No outer NavigationStack here — each tab in GroupTabsHost
        // already owns its own stack. Nesting them swallows the inner
        // toolbar items on iOS 26 (switcher + "Más" go invisible).
        GroupTabsHost(
            container: container,
            group: group,
            onSelectGroup: { picked in
                currentGroupId = picked.id
                Task { await container.currentGroupStore.setGroup(picked) }
            }
        )
        // Force a clean rebuild + state reset on every group switch.
        .id(group.id)
        .task(id: group.id) {
            await container.currentGroupStore.setGroup(group)
            await container.profileStore.refreshIfNeeded()
        }
    }

    /// Resolves the active group from local selection or falls back
    /// to the first available group. Returns `nil` when the caller
    /// has none yet (welcome state).
    private func resolveCurrentGroup(from groups: [GroupListItem]) -> GroupListItem? {
        if let id = currentGroupId, let match = groups.first(where: { $0.id == id }) {
            return match
        }
        return groups.first
    }
}

// MARK: - Bootstrapping

private struct BootstrappingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Cargando…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - Welcome (no groups yet)

private struct WelcomeNoGroupsView: View {
    let container: DependencyContainer
    let onChange: () -> Void

    @State private var isShowingCreateSheet: Bool = false
    @State private var isShowingAcceptSheet: Bool = false
    @State private var isConfirmingSignOut: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.3.sequence")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text(L10n.Welcome.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(L10n.Welcome.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Label(L10n.Welcome.createButton, systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    isShowingAcceptSheet = true
                } label: {
                    Label(L10n.Welcome.acceptButton, systemImage: "ticket")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Text(L10n.Welcome.signOut)
                    .font(.footnote)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task {
            await container.groupsStore.refresh()
            await container.profileStore.refreshIfNeeded()
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateGroupView(container: container) {
                isShowingCreateSheet = false
                onChange()
            }
        }
        .sheet(isPresented: $isShowingAcceptSheet) {
            AcceptInviteSheet(container: container) { _ in
                isShowingAcceptSheet = false
                onChange()
            }
        }
        .alert("Cerrar sesión", isPresented: $isConfirmingSignOut) {
            Button("Cancelar", role: .cancel) {}
            Button("Cerrar sesión", role: .destructive) {
                Task { await container.sessionStore.signOut() }
            }
        } message: {
            Text(L10n.PersonalProfile.signOutConfirmMessage)
        }
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("No pudimos cargar tus grupos")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Reintentar", action: retry)
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
