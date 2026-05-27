import SwiftUI
import RuulCore

/// Apple-native Form for creating a single resource envelope. Bound
/// to `ResourcesStore` so draft state lives in one place. No
/// member-owner picker yet — the field stays on the store for when
/// a later slice adds member selection UI.
struct CreateResourceView: View {
    @Bindable var store: ResourcesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: L10n.Resources.namePlaceholder),
                        text: $store.draftName
                    )
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.next)
                } header: {
                    Text(L10n.Resources.nameLabel)
                }

                Section {
                    TextField(
                        String(localized: L10n.Resources.descriptionPlaceholder),
                        text: $store.draftDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                } header: {
                    Text(L10n.Resources.descriptionLabel)
                }

                Section {
                    Picker(selection: $store.draftType) {
                        ForEach(GroupResourceType.displayOrder, id: \.self) { type in
                            Label(type.label, systemImage: type.systemImageName).tag(type)
                        }
                    } label: {
                        Text(L10n.Resources.typeLabel)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L10n.Resources.typeLabel)
                }

                Section {
                    Picker(selection: $store.draftVisibility) {
                        ForEach(ResourceVisibility.allCases) { v in
                            Text(v.label).tag(v)
                        }
                    } label: {
                        Text(L10n.Resources.visibilityLabel)
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $store.draftOwnershipKind) {
                        // Foundation V1 surfaces group + external only.
                        // .member (= individual on the wire) needs a
                        // member picker we haven't shipped — handled
                        // in a later slice. Backend still accepts it.
                        Text(ResourceOwnershipKind.group.label)
                            .tag(ResourceOwnershipKind.group)
                        Text(ResourceOwnershipKind.external.label)
                            .tag(ResourceOwnershipKind.external)
                    } label: {
                        Text(L10n.Resources.ownershipLabel)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L10n.Resources.visibilityLabel)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Resources.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Resources.cancel)
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
                            Text(L10n.Resources.save)
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
        let ok = await store.createDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
