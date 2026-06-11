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
                Text("Recursos")
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
            let title = activity.payload?["title"]?.stringValue ?? "Recurso"
            out.append(EventDetailRelatedItem(id: id, title: title, trailing: nil))
        }
        return out
    }
}

// MARK: - 5. Decisiones relacionadas (Section + NavigationLink nativo)

struct EventDetailRelatedDecisionsSection: View {
    let eventActivity: [ActivityEvent]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let items = relatedDecisions
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NavigationLink {
                        DecisionDetailView(decisionId: item.id, context: context, container: container)
                    } label: {
                        Label {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            } header: {
                Text("Decisiones")
            }
        }
    }

    /// Decisiones únicas referenciadas en la actividad del evento.
    private var relatedDecisions: [EventDetailRelatedItem] {
        var seen: Set<UUID> = []
        var out: [EventDetailRelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.decisionId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Decisión"
            // El status no está fácilmente disponible sin un fetch extra —
            // F.EVENT.5 puede resolverlo via decision_detail batch.
            out.append(EventDetailRelatedItem(id: id, title: title, trailing: nil))
        }
        return out
    }
}

private struct EventDetailRelatedItem: Identifiable {
    let id: UUID
    let title: String
    let trailing: String?
}
