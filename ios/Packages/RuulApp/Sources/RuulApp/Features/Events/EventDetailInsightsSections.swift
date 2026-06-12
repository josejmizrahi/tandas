import SwiftUI
import RuulCore

// MARK: - Insights del evento (founder 2026-06-12): reglas y fondos
//
// Doctrina R.5V §1: Sections agrupadas por dominio, datos reales del backend,
// secciones vacías se omiten. Cada section carga lazy y falla en silencio
// (no bloquea el detalle del evento).
//
// Los gastos del evento viven en `EventDetailMoneySection` (sección unificada
// lista + CTA, founder 2026-06-12); las votaciones en
// `EventDetailDecisionsSection` (EventDetailRelatedSections.swift).

/// Reglas del contexto que aplican a eventos (trigger `event.*`): late fees,
/// cancelación same-day, etc. El miembro ve a qué se atiene ANTES de que la
/// regla dispare.
struct EventDetailRulesSection: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var rules: [Rule] = []
    @State private var didLoad = false

    var body: some View {
        if !rules.isEmpty {
            Section {
                ForEach(rules) { rule in
                    NavigationLink {
                        RuleDetailView(rule: rule)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text(rule.consequenceDescription)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "bolt.shield")
                                .foregroundStyle(Theme.Tint.warning)
                        }
                    }
                }
            } header: {
                Text("Reglas que aplican (\(rules.count))")
            } footer: {
                Text("Se evalúan automáticamente con los check-ins y cancelaciones de este evento.")
            }
        }
        Color.clear
            .frame(height: 0)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .task { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        let all = (try? await container.rpc.listRules(contextId: context.id)) ?? []
        rules = all.filter { rule in
            rule.isActive && (rule.triggerEventType?.hasPrefix("event.") ?? false)
        }
    }
}

/// Fondos abiertos del espacio (los pools viven a nivel contexto — la sección
/// lo dice explícitamente; no se inventa una relación evento→pool).
struct EventDetailPoolsSection: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var pools: [PoolAccount] = []
    @State private var didLoad = false

    var body: some View {
        if !pools.isEmpty {
            Section {
                ForEach(pools) { pool in
                    NavigationLink {
                        PoolDetailView(poolAccountId: pool.poolAccountId, context: context, container: container)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pool.policyKey == "winner_takes_all" ? "trophy" : "tray.full")
                                .foregroundStyle(Theme.Tint.info)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pool.displayName)
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text(pool.policyLabel)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("Fondos del espacio (\(pools.count))")
            } footer: {
                Text("Los fondos pertenecen a \(context.displayName), no a este evento.")
            }
        }
        Color.clear
            .frame(height: 0)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .task { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        let all = (try? await container.rpc.listContextPools(contextId: context.id)) ?? []
        pools = all.filter { $0.status == "open" || $0.status == "target_reached" }
    }
}
