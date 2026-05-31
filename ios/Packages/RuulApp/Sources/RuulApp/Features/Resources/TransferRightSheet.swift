import SwiftUI
import RuulCore

/// Wraps `transfer_right` for a right resource. Picker over active
/// members + auto save. Reuses the GrantRight L10n where it makes sense.
struct TransferRightSheet: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.GrantRight.memberSection) {
                    Picker(selection: $store.transferRightNewHolderId) {
                        Text(L10n.GrantRight.memberPlaceholder).tag(UUID?.none)
                        ForEach(memberCandidates, id: \.id) { item in
                            Text(item.displayName).tag(Optional(item.membershipId!))
                        }
                    } label: {
                        Text(L10n.GrantRight.memberSection)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.GrantRight.transferTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.GrantRight.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.GrantRight.transferConfirm) }
                    }
                    .disabled(!store.canSaveTransferRight || isSaving)
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
        let ok = await store.saveTransferRight()
        if ok { dismiss() }
    }
}
