import SwiftUI
import RuulCore

/// Sheet for opening a new decision (start_vote). Title + body +
/// method + type + optional explicit options. Leaving options empty
/// surfaces a Sí / No / Abstención hint — the backend will default to
/// no-option voting (vote_value yes/no/abstain/block).
public struct ProposeDecisionSheet: View {
    @Bindable var store: DecisionsStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    public init(store: DecisionsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                titleSection
                bodySection
                methodSection
                legitimacySection
                typeSection
                optionsSection
                if let message = store.draftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Decisions.proposeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Decisions.proposeCancel)) {
                        store.isProposePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Decisions.proposeButton)) {
                        save()
                    }
                    .disabled(!store.canSaveDraftDecision || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        Section(L10n.Decisions.proposeTitleLabel) {
            TextField(String(localized: L10n.Decisions.proposeTitlePlaceholder), text: $store.draftTitle, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        Section(L10n.Decisions.proposeBodyLabel) {
            TextField(
                String(localized: L10n.Decisions.proposeBodyPlaceholder),
                text: $store.draftBody,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    @ViewBuilder
    private var methodSection: some View {
        Section(L10n.Decisions.proposeMethodSection) {
            ForEach(DecisionMethod.selectable) { method in
                Button {
                    store.draftMethod = method
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(method.label, systemImage: method.systemImageName)
                                .font(.body)
                            Text(method.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.draftMethod == method {
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
    private var legitimacySection: some View {
        Section {
            Picker(selection: $store.draftLegitimacySource) {
                ForEach(LegitimacySource.selectable) { source in
                    Label(source.label, systemImage: source.systemImageName)
                        .tag(source)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(store.draftLegitimacySource.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.legitimacySection)
        }
    }

    @ViewBuilder
    private var typeSection: some View {
        Section {
            Picker(String(localized: L10n.Decisions.typeLabel), selection: $store.draftType) {
                ForEach(DecisionType.Group.allCases) { group in
                    let typesInGroup = DecisionType.selectable.filter { $0.group == group }
                    if !typesInGroup.isEmpty {
                        Section {
                            ForEach(typesInGroup) { type in
                                Label(type.label, systemImage: type.systemImageName)
                                    .tag(type)
                            }
                        } header: {
                            Text(group.label)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            Text(store.draftType.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.proposeTypeSection)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            ForEach($store.draftOptions) { $option in
                TextField(String(localized: L10n.Decisions.proposeOptionPlaceholder), text: $option.label)
            }
            .onDelete { offsets in
                store.removeDraftOption(at: offsets)
            }
            Button {
                store.addDraftOption()
            } label: {
                Label(L10n.Decisions.proposeAddOption, systemImage: "plus")
            }
        } header: {
            Text(L10n.Decisions.proposeOptionsSection)
        } footer: {
            Text(L10n.Decisions.proposeOptionsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveDraftDecision(groupId: groupId)
            isSaving = false
        }
    }
}
