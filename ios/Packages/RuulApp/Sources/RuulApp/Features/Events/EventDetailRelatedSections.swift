import SwiftUI
import RuulCore

// MARK: - 4./5. Recursos y Decisiones relacionados (Sections + NavigationLink nativo)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo). Ambas Sections derivan sus items de la actividad del contexto
// filtrada al evento (la pasa el parent como `eventActivity`).

// MARK: - 4. Recursos relacionados (Section + NavigationLink nativo)

struct EventDetailRelatedResourcesSection: View {
    let eventActivity: [ActivityEvent]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let items = relatedResources
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NavigationLink {
                        ResourceDetailViewV2(resourceId: item.id, context: context, container: container)
                    } label: {
                        Label {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Cosas")
            }
        }
    }

    /// Recursos únicos referenciados en la actividad del evento.
    private var relatedResources: [EventDetailRelatedItem] {
        var seen: Set<UUID> = []
        var out: [EventDetailRelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.resourceId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Cosa"
            out.append(EventDetailRelatedItem(id: id, title: title, trailing: nil))
        }
        return out
    }
}

// MARK: - 5. Votaciones (Section + NavigationLink nativo)
//
// Founder 2026-06-12 "quiero ver todo organizado: ... votaciones" — antes solo
// se listaban decisiones referenciadas en la actividad del evento (con título
// sacado del payload). Ahora la section carga `decisions` del contexto (RLS
// read-only) y muestra: las votaciones ABIERTAS del espacio + cualquier
// decisión vinculada a este evento vía actividad (cerradas incluidas), con su
// estado real (mapping canónico §0.3).

struct EventDetailDecisionsSection: View {
    let eventActivity: [ActivityEvent]
    let context: AppContext
    let container: DependencyContainer

    @State private var decisions: [Decision] = []
    @State private var didLoad = false

    var body: some View {
        let items = visibleDecisions
        if !items.isEmpty {
            // R.10.G.1 (2026-06-15) — Apple Music header pattern: prefix(3) +
            // "Ver todas" trailing → DecisionsListView del contexto.
            Section {
                ForEach(Array(items.prefix(3))) { decision in
                    NavigationLink {
                        DecisionDetailView(decisionId: decision.id, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(decision.title)
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text(subtitle(decision))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            let state = RuulStatusBadge.State.decision(decision.status)
                            Image(systemName: state.systemImage)
                                .foregroundStyle(state.tint)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Votaciones (\(items.count))")
                    Spacer()
                    if items.count > 3 {
                        NavigationLink {
                            DecisionsListView(context: context, container: container)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todas")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            } footer: {
                Text("Votaciones abiertas de \(context.displayName) y las vinculadas a este evento.")
            }
        } else if !didLoad {
            // Loader invisible SOLO mientras carga — evita el gap fantasma. Al
            // cargar y quedar vacío no renderiza nada.
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .task { await loadIfNeeded() }
        }
    }

    /// Abiertas del contexto + referenciadas por la actividad del evento
    /// (dedup por id). Abiertas primero, luego por creación descendente.
    private var visibleDecisions: [Decision] {
        let relatedIds = Set(eventActivity.compactMap(\.decisionId))
        return decisions
            .filter { $0.isOpen || relatedIds.contains($0.id) }
            .sorted {
                if $0.isOpen != $1.isOpen { return $0.isOpen }
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
    }

    private func subtitle(_ decision: Decision) -> String {
        if decision.isOpen {
            if let closes = decision.closesAt {
                return "Abierta · cierra \(closes.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Abierta — puedes votar"
        }
        return RuulStatusBadge.State.decision(decision.status).label
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        decisions = (try? await container.rpc.listDecisions(contextId: context.id)) ?? []
    }
}

private struct EventDetailRelatedItem: Identifiable {
    let id: UUID
    let title: String
    let trailing: String?
}
