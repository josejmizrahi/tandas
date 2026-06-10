import SwiftUI
import RuulCore

/// R.8.MiMundo.S6 — Vista cross-context de las reglas visibles en mis
/// contextos. RLS del backend ya filtra lo que puedo ver. Picker
/// Activas / Pausadas / Archivadas + secciones por status.
///
/// Tap → `RuleDetailView(rule:)` en modo read-only. La edición sigue siendo
/// context-scoped (vive en RulesListView por contexto) porque depende de
/// `rules.manage` por contexto.
public struct MyRulesView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var filter: RuleFilter = .active
    @State private var selected: SelectedRule?

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando reglas…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mis reglas")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { sel in
            NavigationStack {
                RuleDetailView(rule: sel.rule)
                    .navigationTitle(sel.rule.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let filtered = aggregated
            .filter { matchesFilter($0.rule.status) }
            .sorted { $0.rule.title < $1.rule.title }

        List {
            filterSection
            if filtered.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(filtered) { entry in
                        Button {
                            selected = SelectedRule(rule: entry.rule, context: entry.context)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Label(filter.headerLabel, systemImage: filter.headerSymbol)
                        .foregroundStyle(filter.headerTint)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("Filtro", selection: $filter) {
                ForEach(RuleFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md,
                                       bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: filter == .active ? "sparkles" : "tray")
                    .foregroundStyle(Theme.Text.tertiary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .active:   return "Sin reglas activas"
        case .paused:   return "Sin reglas pausadas"
        case .archived: return "Sin reglas archivadas"
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(severityTint(entry.rule.severity))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.rule.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let trigger = entry.rule.triggerEventType, !trigger.isEmpty {
                        Text(triggerLabel(trigger)).lineLimit(1)
                        Text("·")
                    }
                    Text(entry.context.displayName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 8)
            Text(statusLabel(entry.rule.status))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusTint(entry.rule.status))
        }
    }

    private func severityTint(_ severity: Int) -> Color {
        switch severity {
        case 3...: return Theme.Tint.critical
        case 2:    return Theme.Tint.warning
        default:   return .purple
        }
    }

    private func triggerLabel(_ raw: String) -> String {
        // Friendly fallback — el detail view trae el copy completo.
        // Aquí solo replico el segmento después del último punto para concisión.
        if let last = raw.split(separator: ".").last {
            return String(last).replacingOccurrences(of: "_", with: " ").capitalized
        }
        return raw
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "active":   return "Activa"
        case "paused":   return "Pausada"
        case "archived": return "Archivada"
        default:         return status.capitalized
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "active":   return Theme.Tint.success
        case "paused":   return Theme.Tint.warning
        case "archived": return Theme.Text.tertiary
        default:         return Theme.Text.secondary
        }
    }

    // MARK: - Filter logic

    private func matchesFilter(_ status: String) -> Bool {
        switch filter {
        case .active:   return status == "active"
        case .paused:   return status == "paused"
        case .archived: return status == "archived"
        }
    }

    // MARK: - Data

    private func load() async {
        if aggregated.isEmpty { phase = .loading }
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            aggregated = []
            phase = .loaded
            return
        }
        await withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts {
                group.addTask {
                    let rules: [Rule] = (try? await container.rpc.listRules(contextId: ctx.id)) ?? []
                    return ContextSlice(context: ctx, rules: rules)
                }
            }
            var all: [Entry] = []
            for await slice in group {
                for rule in slice.rules {
                    all.append(Entry(rule: rule, context: slice.context))
                }
            }
            aggregated = all
        }
        phase = .loaded
    }

    // MARK: - Types

    private struct Entry: Identifiable, Sendable {
        let rule: Rule
        let context: AppContext
        var id: UUID { rule.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let rules: [Rule]
    }

    private struct SelectedRule: Identifiable {
        let rule: Rule
        let context: AppContext
        var id: UUID { rule.id }
    }

    private enum RuleFilter: String, CaseIterable, Identifiable {
        case active, paused, archived
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active:   return "Activas"
            case .paused:   return "Pausadas"
            case .archived: return "Archivadas"
            }
        }
        var headerLabel: String { label }
        var headerSymbol: String {
            switch self {
            case .active:   return "sparkles"
            case .paused:   return "pause.circle.fill"
            case .archived: return "archivebox.fill"
            }
        }
        var headerTint: Color {
            switch self {
            case .active:   return Theme.Tint.success
            case .paused:   return Theme.Tint.warning
            case .archived: return Theme.Text.tertiary
            }
        }
    }
}

#Preview("Mis reglas (demo)") {
    NavigationStack {
        MyRulesView(container: .demo())
    }
}
