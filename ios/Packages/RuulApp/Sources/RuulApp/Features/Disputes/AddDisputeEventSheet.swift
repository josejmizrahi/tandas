import SwiftUI
import RuulCore

/// `.medium` detent sheet that drives `append_dispute_event(...)`.
/// Type picker is limited to user-selectable kinds (comment / evidence
/// / mediation note / other); status_change, resolution and escalation
/// are written by backend actions only.
public struct AddDisputeEventSheet: View {
    @Bindable var store: DisputesStore

    @State private var isSaving: Bool = false

    public init(store: DisputesStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                typeSection
                bodySection
                if let message = store.eventDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Disputes.appendEventSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Disputes.appendEventCancel)) {
                        store.isAppendEventPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Disputes.appendEventConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveEventDraft || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var typeSection: some View {
        Section(L10n.Disputes.eventTypeSection) {
            ForEach(DisputeEventType.userSelectable) { type in
                Button {
                    store.eventDraftType = type
                } label: {
                    HStack {
                        Label(type.label, systemImage: type.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.eventDraftType == type {
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
        Section(L10n.Disputes.eventBodySection) {
            TextField(
                String(localized: L10n.Disputes.eventBodyPlaceholder),
                text: $store.eventDraftBody,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveEventDraft()
            isSaving = false
        }
    }
}
