import SwiftUI
import RuulCore

/// V2-G8 sub-slice 3 — per-rule detail surface for engine rules.
/// Pushed from `RulesListView` (engine section row). Renders the
/// rule sentence (When/If/Then) as a hero + the per-rule firing
/// count + the filtered evaluations list reusing `RuleEvaluationRow`.
///
/// Count caveat: bounded by the loaded evaluations window (default
/// 50 newest in `RuleEvaluationsStore`). Surface labels accordingly
/// so the reader doesn't read it as the all-time total. Full-history
/// count needs a per-rule aggregate RPC (V3).
public struct EngineRuleDetailView: View {
    let rule: EngineRule
    @Bindable var evaluationsStore: RuleEvaluationsStore
    let groupId: UUID

    public init(
        rule: EngineRule,
        evaluationsStore: RuleEvaluationsStore,
        groupId: UUID
    ) {
        self.rule = rule
        self.evaluationsStore = evaluationsStore
        self.groupId = groupId
    }

    public var body: some View {
        List {
            hero
            firingsSection
        }
        .navigationTitle("Regla")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await evaluationsStore.refresh(groupId: groupId)
        }
        .task {
            evaluationsStore.ruleFilter = rule.id
            await evaluationsStore.refreshIfNeeded(groupId: groupId)
        }
        .onDisappear {
            evaluationsStore.ruleFilter = nil
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.tint)
                    Text(rule.title)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("·\(rule.severity)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let trigger = rule.triggerEventType {
                    sentence(label: "Cuando", body: trigger)
                }
                if let condition = rule.condition {
                    sentence(label: "Si", body: condition.kind)
                }
                if !rule.consequences.isEmpty {
                    sentence(
                        label: "Entonces",
                        body: rule.consequences.map(\.kind).joined(separator: ", ")
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func sentence(label: String, body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Firings

    @ViewBuilder
    private var firingsSection: some View {
        Section {
            content
        } header: {
            HStack {
                Text("Disparos recientes")
                Spacer()
                if !matched.isEmpty {
                    Text("\(matched.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !matched.isEmpty {
                Text("Conteo dentro de los \(evaluationsStore.evaluations.count) eventos más recientes del grupo.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch evaluationsStore.phase {
        case .idle, .loading:
            if evaluationsStore.evaluations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                rowsOrEmpty
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No pudimos cargar los disparos", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") {
                    Task { await evaluationsStore.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            rowsOrEmpty
        }
    }

    @ViewBuilder
    private var rowsOrEmpty: some View {
        if matched.isEmpty {
            ContentUnavailableView {
                Label("Sin disparos todavía", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Cuando ocurra un evento que matchee esta regla, lo verás acá.")
            }
            .listRowBackground(Color.clear)
        } else {
            ForEach(matched) { evaluation in
                RuleEvaluationRow(evaluation: evaluation)
            }
        }
    }

    private var matched: [GroupRuleEvaluation] {
        evaluationsStore.evaluations.filter { $0.ruleId == rule.id }
    }
}
