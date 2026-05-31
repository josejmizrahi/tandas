import SwiftUI
import RuulCore

/// Wraps `assign_asset_custodian` for an asset. Picker over active
/// members + optional reason. Same shape pattern as
/// `TransferOwnershipSheet` so member-selection feels consistent.
struct AssignCustodianSheet: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.AssignCustodian.memberSection) {
                    Picker(selection: $store.assignCustodianMembershipId) {
                        Text(L10n.AssignCustodian.memberPlaceholder).tag(UUID?.none)
                        ForEach(memberCandidates, id: \.id) { item in
                            Text(item.displayName).tag(Optional(item.membershipId!))
                        }
                    } label: {
                        Text(L10n.AssignCustodian.memberSection)
                    }
                }

                Section(L10n.AssignCustodian.reasonSection) {
                    TextField(
                        String(localized: L10n.AssignCustodian.reasonPlaceholder),
                        text: $store.assignCustodianReason,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.AssignCustodian.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.AssignCustodian.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.AssignCustodian.save) }
                    }
                    .disabled(!store.canSaveAssignCustodian || isSaving)
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
        let ok = await store.saveAssignCustodian()
        if ok { dismiss() }
    }
}
