import SwiftUI
import RuulCore

/// Form to propose a new cultural norm (Primitiva 20). Backs the
/// "Proponer" toolbar action on `CulturalNormsListView`. Saving
/// inserts the row in `proposed` state; endorsements and retire
/// happen from the list rows themselves.
struct EditCulturalNormView: View {
    @Bindable var store: CulturalNormsStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.CulturalNorms.typeSection) {
                    Picker("type", selection: $store.draftType) {
                        ForEach(CulturalNormType.displayOrder) { type in
                            Label(type.label, systemImage: type.systemImageName)
                                .tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Section(L10n.CulturalNorms.titleSection) {
                    TextField(
                        String(localized: L10n.CulturalNorms.titlePlaceholder),
                        text: $store.draftTitle
                    )
                    .submitLabel(.next)
                }
                Section(L10n.CulturalNorms.bodySection) {
                    TextField(
                        String(localized: L10n.CulturalNorms.bodyPlaceholder),
                        text: $store.draftBody,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }
                Section(L10n.CulturalNorms.visibilitySection) {
                    Picker("visibility", selection: $store.draftVisibility) {
                        ForEach(CulturalNormVisibility.allCases, id: \.self) { vis in
                            Text(vis.label).tag(vis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.CulturalNorms.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.CulturalNorms.cancel)) {
                        store.clearError()
                        store.isCreatePresented = false
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
                            Text(L10n.CulturalNorms.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}
