import SwiftUI
import RuulCore

/// Form for `update_resource_series(...)`. Foundation only patches the
/// ritual annotation (meaning + marker_kind) and the end date; cadence
/// + start_on are immutable from this surface.
public struct EditRitualSheet: View {
    @Bindable var store: RitualsStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    public init(store: RitualsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                markerSection
                meaningSection
                endsOnSection
                if let message = store.editDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Rituals.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Rituals.cancel)) {
                        store.isEditPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Rituals.editConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveEditDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var markerSection: some View {
        Section(L10n.Rituals.markerSection) {
            ForEach(RitualMarkerKind.selectable) { kind in
                Button {
                    store.editDraftMarker = kind
                } label: {
                    HStack {
                        Label(kind.label, systemImage: kind.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.editDraftMarker == kind {
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
    private var meaningSection: some View {
        Section(L10n.Rituals.meaningSection) {
            TextField(
                String(localized: L10n.Rituals.meaningPlaceholder),
                text: $store.editDraftMeaning,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    @ViewBuilder
    private var endsOnSection: some View {
        Section {
            Toggle(isOn: $store.editDraftHasEndDate) {
                Text(L10n.Rituals.hasEndDateToggle)
            }
            if store.editDraftHasEndDate {
                DatePicker(
                    String(localized: L10n.Rituals.endsOnLabel),
                    selection: Binding(
                        get: { store.editDraftEndsOn ?? Date().addingTimeInterval(60*60*24*30) },
                        set: { store.editDraftEndsOn = $0 }
                    ),
                    displayedComponents: [.date]
                )
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveEditDraft(groupId: groupId)
            isSaving = false
        }
    }
}
