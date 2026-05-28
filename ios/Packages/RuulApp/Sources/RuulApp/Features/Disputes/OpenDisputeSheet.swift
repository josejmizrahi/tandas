import SwiftUI
import RuulCore

/// Sheet for opening a generic dispute (not tied to a sanction). The
/// SanctionsListView swipe action still uses `DisputeSanctionSheet` for
/// the sanction-specific shortcut; this one is the canonical
/// `open_dispute(...)` flow surfaced from the disputes list empty
/// state + toolbar add.
public struct OpenDisputeSheet: View {
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
                subjectSection
                titleSection
                descriptionSection
                if let message = store.openDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Disputes.openGenericTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Disputes.openGenericCancel)) {
                        store.isOpenPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Disputes.openGenericConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveOpenDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var subjectSection: some View {
        Section(L10n.Disputes.openSubjectSection) {
            ForEach(DisputeSubjectKind.allCases, id: \.self) { kind in
                Button {
                    store.openDraftSubjectKind = kind
                } label: {
                    HStack {
                        Label(kind.label, systemImage: kind.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.openDraftSubjectKind == kind {
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
    private var titleSection: some View {
        Section(L10n.Disputes.openTitleLabel) {
            TextField(
                String(localized: L10n.Disputes.openTitlePlaceholder),
                text: $store.openDraftTitle,
                axis: .vertical
            )
            .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        Section(L10n.Disputes.openDescriptionLabel) {
            TextField(
                String(localized: L10n.Disputes.openDescriptionPlaceholder),
                text: $store.openDraftDescription,
                axis: .vertical
            )
            .lineLimit(4...10)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveOpenDraft(groupId: groupId)
            isSaving = false
        }
    }
}
