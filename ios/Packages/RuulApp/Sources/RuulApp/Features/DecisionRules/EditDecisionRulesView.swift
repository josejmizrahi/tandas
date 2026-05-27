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
                Section(L10n.DecisionRules.styleSection) {
                    ForEach(DecisionStyle.displayOrder, id: \.self) { style in
                        styleRow(style)
                    }
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
    private func styleRow(_ style: DecisionStyle) -> some View {
        Button {
            store.draftStyle = style
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: style.systemImageName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(store.draftStyle == style ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(style.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.draftStyle == style {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveDraft(groupId: groupId)
        if ok { dismiss() }
    }
}
