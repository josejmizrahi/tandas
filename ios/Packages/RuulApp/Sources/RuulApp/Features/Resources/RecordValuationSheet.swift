import SwiftUI
import RuulCore

/// Wraps `record_asset_valuation`. Numeric amount + currency unit +
/// basis picker (member estimate / invoice / kbb / other). The RPC
/// appends to `group_resource_asset_valuations` and updates
/// `group_resource_assets.current_value`.
struct RecordValuationSheet: View {
    @Bindable var store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.RecordValuation.amountSection) {
                    TextField(
                        String(localized: L10n.RecordValuation.amountLabel),
                        text: $store.valuationAmount
                    )
                    .keyboardType(.decimalPad)
                    TextField(
                        String(localized: L10n.RecordValuation.unitPlaceholder),
                        text: $store.valuationUnit
                    )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                }

                Section(L10n.RecordValuation.basisSection) {
                    Picker(selection: $store.valuationBasis) {
                        ForEach(AssetValuationBasis.allCases) { basis in
                            Text(basis.label).tag(basis)
                        }
                    } label: {
                        Text(L10n.RecordValuation.basisSection)
                    }
                    .pickerStyle(.menu)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.RecordValuation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.RecordValuation.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.RecordValuation.save) }
                    }
                    .disabled(!store.canSaveValuation || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveRecordValuation()
        if ok { dismiss() }
    }
}
