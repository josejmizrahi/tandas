import SwiftUI
import RuulCore

/// Form to log a contribution (Primitiva 9). Doctrina
/// `registrar ≠ aprobar`: el caller registra su propia contribución
/// como `claimed`; verificación es un paso aparte.
struct LogContributionSheet: View {
    @Bindable var store: ContributionsStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.Contributions.typeSection) {
                    Picker(selection: $store.draftType) {
                        ForEach(ContributionType.displayOrder) { type in
                            Label(type.label, systemImage: type.systemImageName).tag(type)
                        }
                    } label: {
                        Text(L10n.Contributions.typeSection)
                    }
                }

                Section(L10n.Contributions.titleSection) {
                    TextField(
                        String(localized: L10n.Contributions.titlePlaceholder),
                        text: $store.draftTitle
                    )
                }

                Section(L10n.Contributions.descriptionSection) {
                    TextField(
                        String(localized: L10n.Contributions.descriptionPlaceholder),
                        text: $store.draftDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                Section(L10n.Contributions.amountSection) {
                    HStack {
                        Text(L10n.Contributions.amountLabel)
                        Spacer()
                        TextField("0", text: $store.draftAmountText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 120)
                    }
                    HStack {
                        Text(L10n.Contributions.unitLabel)
                        Spacer()
                        TextField(
                            String(localized: L10n.Contributions.unitPlaceholder),
                            text: $store.draftUnit
                        )
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 160)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Contributions.logTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Contributions.cancel)) {
                        store.clearError()
                        store.isLogPresented = false
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
                            Text(L10n.Contributions.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}
