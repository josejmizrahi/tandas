import SwiftUI
import RuulCore

/// Compact "Decisiones del grupo" card for `GroupHomeView`. Surfaces
/// Primitivas 6/16/22 — the group's declared decision style + quorum.
/// Tap opens `EditDecisionRulesView` via `store.beginEditing()`.
public struct DecisionRulesCard: View {
    @Bindable var store: DecisionRulesStore

    public init(store: DecisionRulesStore) {
        self.store = store
    }

    public var body: some View {
        Button {
            store.beginEditing()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.resolvedStyle.systemImageName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.DecisionRules.cardHeadline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    primaryLine

                    if let notes = store.rules?.trimmedNotes {
                        Text(notes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: store.hasExplicitRules ? "chevron.right" : "plus.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(store.hasExplicitRules ? "Cambiar" : "Definir"))
    }

    @ViewBuilder
    private var primaryLine: some View {
        if store.hasExplicitRules {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.resolvedStyle.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let q = store.rules?.quorumMin {
                    Text("Quórum mínimo: \(q)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.DecisionRules.quorumNone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.DecisionRules.emptyDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(L10n.DecisionRules.isDefaultHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
