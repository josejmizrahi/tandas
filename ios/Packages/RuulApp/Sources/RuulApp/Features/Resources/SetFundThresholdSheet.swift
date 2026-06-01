import SwiftUI
import RuulCore

/// Wraps `set_fund_threshold` for a fund. Numeric target + currency +
/// optional reason. Backend updates `threshold_target` (and currency
/// when provided) + emits `resource.status_changed`
/// (`kind=threshold_updated`).
struct SetFundThresholdSheet: View {
    @Bindable var store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.SetFundThreshold.amountSection) {
                    TextField(
                        String(localized: L10n.SetFundThreshold.amountLabel),
                        text: $store.fundThresholdAmount
                    )
                    .keyboardType(.decimalPad)
                    TextField(
                        String(localized: L10n.SetFundThreshold.unitPlaceholder),
                        text: $store.fundThresholdUnit
                    )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                }

                Section(L10n.SetFundThreshold.reasonSection) {
                    TextField(
                        String(localized: L10n.SetFundThreshold.reasonPlaceholder),
                        text: $store.fundThresholdReason,
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
            .navigationTitle(L10n.SetFundThreshold.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.SetFundThreshold.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.SetFundThreshold.save) }
                    }
                    .disabled(!store.canSaveFundThreshold || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveFundThreshold()
        if ok { dismiss() }
    }
}
