import SwiftUI
import RuulCore

/// Wraps `assign_slot`. Member picker + optional starts/ends window
/// (defaults to backend now()/now()+1h when unchecked). Reassign uses
/// the same sheet.
struct AssignSlotSheet: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.AssignSlot.memberSection) {
                    Picker(selection: $store.assignSlotMemberId) {
                        Text(L10n.AssignSlot.memberPlaceholder).tag(UUID?.none)
                        ForEach(memberCandidates, id: \.id) { item in
                            Text(item.displayName).tag(Optional(item.membershipId!))
                        }
                    } label: {
                        Text(L10n.AssignSlot.memberSection)
                    }
                }

                Section(L10n.AssignSlot.windowSection) {
                    Toggle(isOn: $store.assignSlotCustomWindow) {
                        Text(L10n.AssignSlot.customWindowToggle)
                    }
                    if store.assignSlotCustomWindow {
                        DatePicker(
                            selection: $store.assignSlotStartsAt,
                            displayedComponents: [.date, .hourAndMinute]
                        ) {
                            Text(L10n.AssignSlot.startsLabel)
                        }
                        DatePicker(
                            selection: $store.assignSlotEndsAt,
                            in: store.assignSlotStartsAt.addingTimeInterval(60)...,
                            displayedComponents: [.date, .hourAndMinute]
                        ) {
                            Text(L10n.AssignSlot.endsLabel)
                        }
                    }
                }

                Section(L10n.AssignSlot.reasonSection) {
                    TextField(
                        String(localized: L10n.AssignSlot.reasonPlaceholder),
                        text: $store.assignSlotReason,
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
            .navigationTitle(L10n.AssignSlot.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.AssignSlot.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.AssignSlot.save) }
                    }
                    .disabled(!store.canSaveAssignSlot || isSaving)
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
        let ok = await store.saveAssignSlot()
        if ok { dismiss() }
    }
}
