import SwiftUI
import RuulCore

/// Form-based editor for `groups.decision_rules`. Bound to
/// `DecisionRulesStore`; the View doesn't own the draft state.
struct EditDecisionRulesView: View {
    @Bindable var store: DecisionRulesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false
    @State private var quorumEnabled: Bool = false
    @State private var quorumValue: Int = 2

    var body: some View {
        NavigationStack {
            Form {
                // V2-G2 sub-slice 8 — canonical method + legitimacy live
                // here (group-level config). Per-decision sheets pick
                // these as defaults when proposing.
                Section {
                    ForEach(DecisionMethod.selectable) { method in
                        methodRow(method)
                    }
                } header: {
                    Text(L10n.DecisionRules.methodSection)
                } footer: {
                    Text(L10n.DecisionRules.methodFooter)
                }

                Section {
                    ForEach(LegitimacySource.selectable) { source in
                        legitimacyRow(source)
                    }
                } header: {
                    Text(L10n.DecisionRules.legitimacySection)
                } footer: {
                    Text(L10n.DecisionRules.legitimacyFooter)
                }

                Section(L10n.DecisionRules.quorumSection) {
                    Toggle(isOn: $quorumEnabled) {
                        Text(L10n.DecisionRules.quorumLabel)
                    }
                    if quorumEnabled {
                        Stepper(value: $quorumValue, in: 1...50) {
                            Text("\(quorumValue) miembros")
                                .monospacedDigit()
                        }
                    }
                }

                Section(L10n.DecisionRules.notesSection) {
                    TextField(
                        String(localized: L10n.DecisionRules.notesPlaceholder),
                        text: $store.draftNotes,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.DecisionRules.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.DecisionRules.cancel)
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
                            Text(L10n.DecisionRules.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .onAppear {
                if let q = store.draftQuorum {
                    quorumEnabled = true
                    quorumValue = max(1, q)
                } else {
                    quorumEnabled = false
                    quorumValue = 2
                }
            }
            .onChange(of: quorumEnabled) { _, enabled in
                store.draftQuorum = enabled ? quorumValue : nil
            }
            .onChange(of: quorumValue) { _, value in
                if quorumEnabled { store.draftQuorum = value }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    @ViewBuilder
    private func methodRow(_ method: DecisionMethod) -> some View {
        Button {
            store.draftMethod = method
        } label: {
            optionRowContent(
                systemImage: method.systemImageName,
                label: method.label,
                subtitle: method.subtitle,
                isSelected: store.draftMethod == method
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func legitimacyRow(_ source: LegitimacySource) -> some View {
        Button {
            store.draftLegitimacySource = source
        } label: {
            optionRowContent(
                systemImage: source.systemImageName,
                label: source.label,
                subtitle: source.subtitle,
                isSelected: store.draftLegitimacySource == source
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionRowContent(
        systemImage: String,
        label: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
