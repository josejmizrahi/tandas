import SwiftUI
import RuulCore

/// Apple-native Form for creating a single text rule. Bound to
/// `RulesStore` so the draft state lives in one place.
struct EditRuleView: View {
    @Bindable var store: RulesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: L10n.Rules.ruleTitlePlaceholder),
                        text: $store.draftTitle
                    )
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.next)
                } header: {
                    Text(L10n.Rules.ruleTitleLabel)
                }

                Section {
                    TextField(
                        String(localized: L10n.Rules.bodyPlaceholder),
                        text: $store.draftBody,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                } header: {
                    Text(L10n.Rules.bodyLabel)
                }

                Section {
                    Picker(selection: $store.draftType) {
                        ForEach(GroupRuleType.displayOrder, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text(L10n.Rules.typeLabel)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L10n.Rules.typeLabel)
                }

                Section {
                    Stepper(
                        "\(String(localized: L10n.Rules.severityLabel)) · \(store.draftSeverity)",
                        value: $store.draftSeverity,
                        in: 0...5
                    )
                } header: {
                    Text(L10n.Rules.severityLabel)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Rules.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Rules.cancel)
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
                            Text(L10n.Rules.save)
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
