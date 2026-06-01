import SwiftUI
import RuulCore

/// Form to issue a new sanction. Foundation scope only exposes the
/// lighter kinds (warning / monetary / repair_task / reputation_note /
/// other) — suspension/loss_of_role/expulsion mutate other state and
/// land in a later slice with their own confirmation UX.
struct IssueSanctionSheet: View {
    @Bindable var store: SanctionsStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.Sanctions.kindSection) {
                    Picker(selection: $store.draftKind) {
                        ForEach(SanctionKind.foundationIssuable) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text(L10n.Sanctions.kindSection)
                    }
                    Text(store.draftKind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.Sanctions.targetSection) {
                    if eligibleTargets.isEmpty {
                        Text("Aún no hay miembros activos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $store.draftTargetMembershipId) {
                            Text("Selecciona…").tag(UUID?.none)
                            ForEach(eligibleTargets, id: \.id) { item in
                                Text(item.displayName).tag(Optional(item.membershipId!))
                            }
                        } label: {
                            Text(L10n.Sanctions.targetSection)
                        }
                    }
                }

                Section(L10n.Sanctions.reasonSection) {
                    TextField(
                        String(localized: L10n.Sanctions.reasonPlaceholder),
                        text: $store.draftReason,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if store.draftKind.requiresAmount {
                    Section(L10n.Sanctions.amountSection) {
                        HStack {
                            Text(L10n.Sanctions.amountLabel)
                            Spacer()
                            TextField("0", value: $store.draftAmount, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .frame(maxWidth: 140)
                        }
                        HStack {
                            Text(L10n.Sanctions.unitLabel)
                            Spacer()
                            TextField("MXN", text: $store.draftUnit)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 100)
                        }
                    }
                }

                Section(L10n.Sanctions.endsAtSection) {
                    Toggle("Tiene vencimiento", isOn: Binding(
                        get: { store.draftEndsAt != nil },
                        set: { on in store.draftEndsAt = on ? (store.draftEndsAt ?? Date().addingTimeInterval(7 * 86_400)) : nil }
                    ))
                    if let _ = store.draftEndsAt {
                        DatePicker(
                            "Vence",
                            selection: Binding(
                                get: { store.draftEndsAt ?? Date() },
                                set: { store.draftEndsAt = $0 }
                            ),
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Sanctions.issueTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Sanctions.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.Sanctions.issueButton)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .task {
                await membersStore.refreshIfNeeded(groupId: groupId)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    /// Active memberships excluding the current user (don't sanction
    /// yourself by accident). Pulled straight from MembersStore so we
    /// don't re-query.
    private var eligibleTargets: [MembershipBoundaryItem] {
        membersStore.items.filter { item in
            item.kind == .membership
                && item.status == .active
                && item.membershipId != nil
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
