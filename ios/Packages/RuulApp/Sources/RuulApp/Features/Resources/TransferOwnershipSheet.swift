import SwiftUI
import RuulCore

/// Wraps `set_resource_ownership` for an existing resource (Primitiva
/// 18). Lets the caller switch ownership_kind (group / member /
/// external) and, when `.member`, pick the new owner from the
/// `MembersStore` list. An optional note is persisted into
/// `p_metadata.note` so the system event keeps the reason.
struct TransferOwnershipSheet: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.TransferOwnership.kindSection) {
                    Picker(selection: $store.transferKind) {
                        ForEach(ResourceOwnershipKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text(L10n.TransferOwnership.kindSection)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.transferKind) { _, new in
                        if new != .member { store.transferOwnerMembershipId = nil }
                    }
                }

                if store.transferKind == .member {
                    Section(L10n.TransferOwnership.memberSection) {
                        Picker(selection: $store.transferOwnerMembershipId) {
                            Text(L10n.TransferOwnership.memberPlaceholder).tag(UUID?.none)
                            ForEach(memberCandidates, id: \.id) { item in
                                Text(item.displayName).tag(Optional(item.membershipId!))
                            }
                        } label: {
                            Text(L10n.TransferOwnership.memberSection)
                        }
                    }
                }

                Section(L10n.TransferOwnership.noteSection) {
                    TextField(
                        String(localized: L10n.TransferOwnership.notePlaceholder),
                        text: $store.transferNote,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.TransferOwnership.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.TransferOwnership.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.TransferOwnership.save) }
                    }
                    .disabled(!store.canSaveTransfer || isSaving)
                }
            }
            .task {
                await membersStore.refreshIfNeeded(groupId: groupId)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var memberCandidates: [MembershipBoundaryItem] {
        membersStore.items.filter { $0.kind == .membership && $0.membershipId != nil }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveTransfer(groupId: groupId)
        if ok { dismiss() }
    }
}
