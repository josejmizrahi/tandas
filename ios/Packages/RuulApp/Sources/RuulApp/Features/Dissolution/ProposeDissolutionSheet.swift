import SwiftUI
import RuulCore

/// Form for `propose_dissolution(...)`. Foundation V1 collects only the
/// reason text; backend defaults the `plan` / `asset_disposition` /
/// `obligations_plan` jsonb to empty until a richer liquidation wizard
/// lands. Backend auto-creates the supermajority vote (14 days,
/// 66.66% threshold, 50% quorum) and flips the group to `dissolving`.
public struct ProposeDissolutionSheet: View {
    @Bindable var store: DissolutionStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    public init(store: DissolutionStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L10n.Dissolution.proposeWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section(L10n.Dissolution.reasonSection) {
                    TextField(
                        String(localized: L10n.Dissolution.reasonPlaceholder),
                        text: $store.draftReason,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                }
                if let message = store.draftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Dissolution.proposeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Dissolution.cancel)) {
                        store.isProposePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Dissolution.proposeConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveDraft(groupId: groupId)
            isSaving = false
        }
    }
}
