import SwiftUI
import RuulCore

/// D1 — Sheet that replaces the standalone `GroupListView` as a switcher
/// surface. Mirrors Calendar / Reminders / Notes: a sheet with the
/// caller's groups + create + "tengo un código" + check next to the
/// active group. Tapping a row fires `onSelect(group)` and dismisses.
/// Empty state surfaces Create / Accept directly so a brand-new user
/// has something to do.
public struct GroupSwitcherSheet: View {
    let container: DependencyContainer
    let currentGroupId: UUID?
    let onSelect: (GroupListItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingCreateSheet: Bool = false
    @State private var isShowingAcceptSheet: Bool = false
    @State private var isShowingRequestSheet: Bool = false

    public init(
        container: DependencyContainer,
        currentGroupId: UUID?,
        onSelect: @escaping (GroupListItem) -> Void
    ) {
        self.container = container
        self.currentGroupId = currentGroupId
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            List {
                content
                actionsSection
            }
            .navigationTitle(L10n.GroupSwitcher.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: L10n.GroupSwitcher.close)) {
                        dismiss()
                    }
                }
            }
            .refreshable {
                await container.groupsStore.refresh()
            }
            .task {
                await container.groupsStore.refresh()
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
            .sheet(isPresented: $isShowingRequestSheet) {
                RequestMembershipSheet(container: container) { _ in
                    // Don't auto-dismiss — request membership leaves the
                    // user in 'requested' status. The sheet itself
                    // surfaces the success copy; user closes manually.
                    Task { await container.groupsStore.refresh() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch container.groupsStore.phase {
        case .idle, .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView().padding(.vertical, 16)
                    Spacer()
                }
            }
        case .failed(let message):
            Section {
                ContentUnavailableView {
                    Label(L10n.GroupSwitcher.errorTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(String(localized: L10n.GroupSwitcher.retry)) {
                        Task { await container.groupsStore.refresh() }
                    }
                }
            }
        case .loaded:
            if container.groupsStore.groups.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.GroupSwitcher.emptyTitle, systemImage: "person.3")
                    } description: {
                        Text(L10n.GroupSwitcher.emptyDescription)
                    }
                }
            } else {
                Section(L10n.GroupSwitcher.groupsSection) {
                    ForEach(container.groupsStore.groups) { group in
                        Button {
                            onSelect(group)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let summary = group.purposeSummary, !summary.isEmpty {
                                        Text(summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if currentGroupId == group.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.GroupSwitcher.actionsSection) {
            Button {
                isShowingCreateSheet = true
            } label: {
                Label(L10n.GroupSwitcher.createButton, systemImage: "plus")
            }
            Button {
                isShowingAcceptSheet = true
            } label: {
                Label(L10n.GroupSwitcher.acceptButton, systemImage: "ticket")
            }
            Button {
                isShowingRequestSheet = true
            } label: {
                Label(L10n.GroupSwitcher.requestButton, systemImage: "hand.raised")
            }
        }
    }
}
