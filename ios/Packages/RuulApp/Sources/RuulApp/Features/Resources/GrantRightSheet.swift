import SwiftUI
import RuulCore

/// Wraps `grant_right` for a right resource. Holder picker + kind +
/// optional expiry + transferable + conditions text. Re-grant uses the
/// same sheet (the RPC is an upsert).
struct GrantRightSheet: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.GrantRight.memberSection) {
                    Picker(selection: $store.grantRightHolderId) {
                        Text(L10n.GrantRight.memberPlaceholder).tag(UUID?.none)
                        ForEach(memberCandidates, id: \.id) { item in
                            Text(item.displayName).tag(Optional(item.membershipId!))
                        }
                    } label: {
                        Text(L10n.GrantRight.memberSection)
                    }
                }

                Section(L10n.GrantRight.kindSection) {
                    Picker(selection: $store.grantRightKind) {
                        ForEach(ResourceRightKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text(L10n.GrantRight.kindSection)
                    }
                    .pickerStyle(.menu)
                }

                Section(L10n.GrantRight.expiresSection) {
                    Toggle(isOn: $store.grantRightHasExpiry) {
                        Text(L10n.GrantRight.expiresToggle)
                    }
                    if store.grantRightHasExpiry {
                        DatePicker(
                            selection: $store.grantRightExpiresAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        ) {
                            Text(L10n.ResourceDetail.rightExpiresLabel)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $store.grantRightTransferable) {
                        Text(L10n.GrantRight.transferableToggle)
                    }
                }

                Section(L10n.GrantRight.conditionsSection) {
                    TextField(
                        String(localized: L10n.GrantRight.conditionsPlaceholder),
                        text: $store.grantRightConditions,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                Section(L10n.GrantRight.reasonSection) {
                    TextField(
                        String(localized: L10n.GrantRight.reasonPlaceholder),
                        text: $store.grantRightReason,
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
            .navigationTitle(L10n.GrantRight.title)
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
                        else { Text(L10n.GrantRight.save) }
                    }
                    .disabled(!store.canSaveGrantRight || isSaving)
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
        let ok = await store.saveGrantRight()
        if ok { dismiss() }
    }
}
