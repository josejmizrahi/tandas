import SwiftUI
import RuulCore

/// Form to grant a mandate (Primitiva 23). Defaults to
/// `principal = group, type = represent, no end date`. The
/// representative picker pulls from the `MembersStore` active
/// boundary; non-active rows (invites/suspended/left) are
/// filtered out.
struct GrantMandateSheet: View {
    @Bindable var store: MandatesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.Mandates.representativeSection) {
                    if eligibleRepresentatives.isEmpty {
                        Text("Aún no hay miembros activos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $store.draftRepresentativeMembershipId) {
                            Text(L10n.Mandates.representativeNone).tag(UUID?.none)
                            ForEach(eligibleRepresentatives, id: \.id) { item in
                                Text(item.displayName).tag(Optional(item.membershipId!))
                            }
                        } label: {
                            Text(L10n.Mandates.representativeSection)
                        }
                    }
                }

                Section(L10n.Mandates.typeSection) {
                    Picker(selection: $store.draftType) {
                        ForEach(MandateType.displayOrder) { type in
                            Label(type.label, systemImage: type.systemImageName).tag(type)
                        }
                    } label: {
                        Text(L10n.Mandates.typeSection)
                    }
                }

                Section(L10n.Mandates.principalSection) {
                    Picker(selection: $store.draftPrincipalType) {
                        // Foundation only exposes group + membership.
                        // committee/role land with C1 + B3 respectively
                        // (need a picker over committees / roles).
                        ForEach([MandatePrincipalType.group], id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    } label: {
                        Text(L10n.Mandates.principalSection)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(L10n.Mandates.endsAtSection) {
                    Toggle("Tiene vencimiento", isOn: $store.draftHasEndDate)
                    if store.draftHasEndDate {
                        DatePicker(
                            "Vence",
                            selection: Binding(
                                get: { store.draftEndsAt ?? Date().addingTimeInterval(30 * 86_400) },
                                set: { store.draftEndsAt = $0 }
                            ),
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                    } else {
                        Text(L10n.Mandates.endsAtNone)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Mandates.grantTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Mandates.cancel)) {
                        store.clearError()
                        store.isGrantPresented = false
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            let ok = await store.saveDraft(groupId: groupId)
                            if ok { dismiss() }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.Mandates.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .task {
                await membersStore.refreshIfNeeded(groupId: groupId)
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var eligibleRepresentatives: [MembershipBoundaryItem] {
        membersStore.items.filter { item in
            item.isActiveMembership && item.membershipId != nil
        }
    }
}
