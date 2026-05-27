import SwiftUI
import RuulCore

/// Form to dispute an existing sanction. Triggered from a swipe action
/// on `SanctionRowView` (or from a future Sanction detail view). The
/// sheet itself only collects a summary; backend `dispute_sanction`
/// does the rest: creates the `group_disputes` row, flips the
/// sanction's status to `disputed`, writes a system event.
struct DisputeSanctionSheet: View {
    @Bindable var store: DisputesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.Disputes.summarySection) {
                    TextField(
                        String(localized: L10n.Disputes.summaryPlaceholder),
                        text: $store.draftSummary,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Disputes.openTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Disputes.cancel)
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
                            Text(L10n.Disputes.openButton)
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
