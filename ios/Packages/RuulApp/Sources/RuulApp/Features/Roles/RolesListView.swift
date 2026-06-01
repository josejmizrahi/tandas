import SwiftUI
import RuulCore

/// Surface admin for Primitiva 17. Settings.app-style list with two
/// sections (sistema + custom). Tap a row to view/edit; system roles
/// open the editor read-only (backend blocks mutations). Toolbar add
/// opens the editor in create mode.
public struct RolesListView: View {
    @Bindable var store: RolesStore
    let groupId: UUID

    public init(store: RolesStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Roles.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginCreating()
                } label: {
                    Label(L10n.Roles.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isEditorPresented) {
            RoleEditorView(store: store, groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Roles.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Roles.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.systemRoles.isEmpty {
                Section(L10n.Roles.systemSection) {
                    ForEach(store.systemRoles) { role in
                        row(for: role)
                    }
                    Text(L10n.Roles.systemReadOnlyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.customRoles.isEmpty {
                Section(L10n.Roles.customSection) {
                    ContentUnavailableView {
                        Label(L10n.Roles.emptyTitle, systemImage: "person.crop.rectangle.badge.plus")
                    } description: {
                        Text(L10n.Roles.emptyDescription)
                    } actions: {
                        Button {
                            store.beginCreating()
                        } label: {
                            Text(L10n.Roles.addButton)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section(L10n.Roles.customSection) {
                    ForEach(store.customRoles) { role in
                        row(for: role)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for role: GroupRole) -> some View {
        Button {
            store.beginEditing(role)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(role.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if role.isDefault {
                        chip(role.isDefault ? L10n.Roles.defaultLabel : L10n.Roles.systemLabel)
                    }
                    if role.isSystem && !role.isDefault {
                        chip(L10n.Roles.systemLabel)
                    }
                    Spacer()
                    if let count = role.memberCountLabel {
                        Text(count)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let description = role.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("^[\(role.permissionKeys.count) permisos](inflect: true)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chip(_ label: LocalizedStringResource) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder").font(.body.weight(.semibold))
            Text("placeholder permisos").font(.caption).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
