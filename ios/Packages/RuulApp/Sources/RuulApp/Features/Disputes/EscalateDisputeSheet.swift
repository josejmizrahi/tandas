import SwiftUI
import RuulCore

/// Sheet for `escalate_dispute_to_vote(...)`. Creates a linked
/// decision (the Decisions store does NOT need to be touched here —
/// backend writes the group_decisions row + flips the dispute status).
/// Method picker mirrors the propose-decision sheet.
public struct EscalateDisputeSheet: View {
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
                titleSection
                methodSection
                closesAtSection
                if let message = store.escalateDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Disputes.escalateSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Disputes.escalateCancel)) {
                        store.isEscalatePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Disputes.escalateConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveEscalateDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        Section(L10n.Disputes.escalateDecisionTitle) {
            TextField(
                String(localized: L10n.Decisions.proposeTitlePlaceholder),
                text: $store.escalateDraftTitle,
                axis: .vertical
            )
            .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var methodSection: some View {
        Section(L10n.Disputes.escalateMethodSection) {
            ForEach(DecisionMethod.selectable) { method in
                Button {
                    store.escalateDraftMethod = method
                } label: {
                    HStack {
                        Label(method.label, systemImage: method.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.escalateDraftMethod == method {
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
    private var closesAtSection: some View {
        Section {
            Toggle(isOn: $store.escalateDraftHasCloseDate) {
                Text(L10n.Disputes.escalateClosesAtToggle)
            }
            if store.escalateDraftHasCloseDate {
                DatePicker(
                    String(localized: L10n.Disputes.escalateClosesAtLabel),
                    selection: Binding(
                        get: { store.escalateDraftClosesAt ?? Date().addingTimeInterval(60*60*24*3) },
                        set: { store.escalateDraftClosesAt = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveEscalateDraft(groupId: groupId)
            isSaving = false
        }
    }
}
