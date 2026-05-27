import SwiftUI
import RuulCore

/// Apple-native Form for editing one purpose row at a time. Bound to
/// `PurposeStore` so the kind/body/visibility draft state lives in
/// one place; the View doesn't own the data.
struct EditPurposeView: View {
    @Bindable var store: PurposeStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $store.editingKind) {
                        ForEach(GroupPurposeKind.displayOrder, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text(L10n.Purpose.kindLabel)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(store.editingKind.subtitle)
                }

                Section {
                    TextField(
                        String(localized: L10n.Purpose.bodyPlaceholder),
                        text: $store.draftBody,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                } header: {
                    Text(L10n.Purpose.bodyLabel)
                }

                Section {
                    Picker(selection: $store.draftVisibility) {
                        ForEach(PurposeVisibility.allCases) { vis in
                            Text(vis.label).tag(vis)
                        }
                    } label: {
                        Text(L10n.Purpose.visibilityLabel)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L10n.Purpose.visibilityLabel)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Purpose.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Purpose.cancel)
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
                            Text(L10n.Purpose.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
