import SwiftUI
import RuulCore

/// Sheet for `record_dispute_resolution(...)`. Picks a method + writes
/// the agreement text. Backend gates by mediator / `disputes.resolve`,
/// so non-mediators see a permission error on save.
public struct ResolveDisputeView: View {
    @Bindable var store: DisputesStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    public init(store: DisputesStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                methodSection
                bodySection
                if let message = store.resolveDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Disputes.resolveSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Disputes.resolveCancel)) {
                        store.isResolvePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Disputes.resolveConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveResolveDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var methodSection: some View {
        Section(L10n.Disputes.resolveMethodSection) {
            ForEach(DisputeResolutionMethod.selectable, id: \.self) { method in
                Button {
                    store.resolveDraftMethod = method
                } label: {
                    HStack {
                        Text(method.label)
                        Spacer()
                        if store.resolveDraftMethod == method {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        Section(L10n.Disputes.resolveBodySection) {
            TextField(
                String(localized: L10n.Disputes.resolveBodyPlaceholder),
                text: $store.resolveDraftText,
                axis: .vertical
            )
            .lineLimit(3...10)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveResolveDraft(groupId: groupId)
            isSaving = false
        }
    }
}
