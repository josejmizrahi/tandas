import SwiftUI
import RuulCore

/// V2-G3.5 — "Disparos" feed: the audit row per engine evaluation
/// hidratada con el outcome del predicate + per-action result. Pushed
/// from `RulesListView` via the toolbar; per-rule filter applied
/// client-side when `ruleFilter` is set.
public struct RuleEvaluationsView: View {
    @Bindable var store: RuleEvaluationsStore
    let groupId: UUID

    public init(store: RuleEvaluationsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle("Disparos del engine")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(groupId: groupId) }
        .task { await store.refreshIfNeeded(groupId: groupId) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if store.evaluations.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    RuleEvaluationRow(evaluation: placeholder)
                        .redacted(reason: .placeholder)
                }
            } else {
                loaded
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No pudimos cargar los disparos", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.visibleEvaluations.isEmpty {
                ContentUnavailableView {
                    Label("Sin disparos todavía", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Cuando ocurra un evento que matchee una regla con engine, lo verás acá con su resultado y consecuencias.")
                }
                .listRowBackground(Color.clear)
            } else {
                loaded
            }
        }
    }

    @ViewBuilder
    private var loaded: some View {
        Section {
            ForEach(store.visibleEvaluations) { evaluation in
                RuleEvaluationRow(evaluation: evaluation)
            }
            if store.hasMore && store.ruleFilter == nil {
                Button {
                    Task { await store.loadMore(groupId: groupId) }
                } label: {
                    Text("Cargar más")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var placeholder: GroupRuleEvaluation {
        GroupRuleEvaluation(
            id: UUID(), ruleId: UUID(), ruleTitle: "Cargando…",
            ruleVersionId: UUID(),
            matched: true, depth: 0, createdAt: Date()
        )
    }
}

/// Compact row: title + trigger + outcome chip + action results. Tap
/// could push a future RuleEvaluationDetailView; for G3.5 the row is
/// self-contained.
private struct RuleEvaluationRow: View {
    let evaluation: GroupRuleEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconTint)
                Text(evaluation.ruleTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(evaluation.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let trigger = evaluation.triggerEventType {
                Text("Evento: \(trigger)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let predicate = evaluation.matchedPredicate, let reason = predicate.reason {
                HStack(spacing: 6) {
                    Image(systemName: predicate.passed ? "checkmark.seal" : "xmark.seal")
                        .foregroundStyle(predicate.passed ? .green : .secondary)
                    Text(predicate.passed ? "Predicate: \(reason)" : "No coincidió: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(evaluation.actionsEmitted) { action in
                actionRow(action)
            }

            if evaluation.cycleDetected {
                Label("Ciclo detectado — consecuencias no disparadas", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        if evaluation.cycleDetected { return "arrow.triangle.2.circlepath" }
        if !evaluation.matched { return "minus.circle" }
        if !evaluation.failedActions.isEmpty { return "exclamationmark.octagon" }
        if !evaluation.emittedActions.isEmpty { return "bolt.fill" }
        return "bolt.horizontal.circle"
    }

    private var iconTint: Color {
        if evaluation.cycleDetected { return .orange }
        if !evaluation.matched { return .secondary }
        if !evaluation.failedActions.isEmpty { return .red }
        if !evaluation.emittedActions.isEmpty { return .accentColor }
        return .secondary
    }

    @ViewBuilder
    private func actionRow(_ action: RuleActionResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: action.isFailed
                  ? "xmark.octagon"
                  : (action.isSync ? "bolt.fill" : "tray.and.arrow.up"))
                .foregroundStyle(action.isFailed ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(actionTitle(action))
                    .font(.caption)
                    .foregroundStyle(action.isFailed ? .red : .primary)
                if let err = action.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func actionTitle(_ action: RuleActionResult) -> String {
        var pieces: [String] = [action.kind, action.status]
        if let audience = action.audience { pieces.append("audience=\(audience)") }
        if let recipients = action.recipients { pieces.append("→ \(recipients)") }
        if let state = action.newState { pieces.append(state) }
        return pieces.joined(separator: " · ")
    }
}
