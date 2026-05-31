import SwiftUI
import RuulCore

/// Wraps `mark_asset_condition`. Inline radio of the 5 canonical
/// conditions (good/used/damaged/repaired/retired) + optional reason.
/// Backend decides the emitted event_type
/// (`resource.damaged`/`.repaired`/`.status_changed`) from the
/// transition, so the iOS side only ships the desired final state.
struct MarkConditionSheet: View {
    @Bindable var store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.MarkCondition.conditionSection) {
                    ForEach(AssetCondition.allCases) { condition in
                        Button {
                            store.markConditionDraft = condition
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: condition.systemImageName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                Text(condition.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if store.markConditionDraft == condition {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(L10n.MarkCondition.reasonSection) {
                    TextField(
                        String(localized: L10n.MarkCondition.reasonPlaceholder),
                        text: $store.markConditionReason,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.MarkCondition.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.MarkCondition.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() }
                        else { Text(L10n.MarkCondition.save) }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveMarkCondition()
        if ok { dismiss() }
    }
}
