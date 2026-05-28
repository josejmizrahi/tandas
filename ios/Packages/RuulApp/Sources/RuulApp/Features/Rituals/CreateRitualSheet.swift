import SwiftUI
import RuulCore

/// Form for `create_resource_series(...)` flagged as ritual. Collects
/// marker kind + cadence + meaning + start/end dates. `pattern` and
/// `template_payload` stay backend-default in Foundation V1.
public struct CreateRitualSheet: View {
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
                cadenceSection
                meaningSection
                datesSection
                if let message = store.createDraftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Rituals.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Rituals.cancel)) {
                        store.isCreatePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Rituals.createConfirm)) {
                        save()
                    }
                    .disabled(!store.canSaveCreateDraft || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var markerSection: some View {
        Section(L10n.Rituals.markerSection) {
            ForEach(RitualMarkerKind.selectable) { kind in
                Button {
                    store.createDraftMarker = kind
                } label: {
                    HStack {
                        Label(kind.label, systemImage: kind.systemImageName)
                            .font(.body)
                        Spacer()
                        if store.createDraftMarker == kind {
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
    private var cadenceSection: some View {
        Section(L10n.Rituals.cadenceSection) {
            Picker(String(localized: L10n.Rituals.cadenceSection), selection: $store.createDraftCadence) {
                ForEach(RitualCadence.displayOrder) { cadence in
                    Text(cadence.label).tag(cadence)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var meaningSection: some View {
        Section(L10n.Rituals.meaningSection) {
            TextField(
                String(localized: L10n.Rituals.meaningPlaceholder),
                text: $store.createDraftMeaning,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    @ViewBuilder
    private var datesSection: some View {
        Section(L10n.Rituals.datesSection) {
            DatePicker(
                String(localized: L10n.Rituals.startsOnLabel),
                selection: $store.createDraftStartsOn,
                displayedComponents: [.date]
            )
            Toggle(isOn: $store.createDraftHasEndDate) {
                Text(L10n.Rituals.hasEndDateToggle)
            }
            if store.createDraftHasEndDate {
                DatePicker(
                    String(localized: L10n.Rituals.endsOnLabel),
                    selection: Binding(
                        get: { store.createDraftEndsOn ?? store.createDraftStartsOn.addingTimeInterval(60*60*24*30) },
                        set: { store.createDraftEndsOn = $0 }
                    ),
                    in: store.createDraftStartsOn...,
                    displayedComponents: [.date]
                )
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveCreateDraft(groupId: groupId)
            isSaving = false
        }
    }
}
