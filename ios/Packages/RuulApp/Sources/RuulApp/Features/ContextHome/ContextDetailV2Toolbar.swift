import SwiftUI
import RuulCore

// MARK: - Toolbar (P0 fix 2026-06-08 — acciones específicas por contexto)
//
// Personal context: sin acciones de gestión.
// Collective context:
//   - Trailing "+": Menu con descriptor.actions (create_resource, invite,
//     record_expense, create_decision, create_event, create_rule, create_child).
//   - Trailing "ellipsis": Menu con drill-downs específicos del contexto
//     (Reglas, Configuración).

struct ContextDetailV2Toolbar: ToolbarContent {
    let context: AppContext
    let actions: [AvailableAction]?
    let quickActionsRouter: NoopActionRouter
    @Binding var pushedActionDestination: ContextDetailViewV2.QuickActionPush?
    @Binding var isShowingSettings: Bool

    var body: some ToolbarContent {
        if context.isPersonal {
            // Personal context — sin acciones de gestión.
            EmptyToolbarContent()
        } else {
            if let actions = actions, !actions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    quickActionsMenu(actions: actions)
                }
                // R.5V.Toolbar.Spacers — separa "+" (quick actions) del
                // "ellipsis" (más opciones) en cápsulas Liquid Glass distintas.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        pushedActionDestination = .rules
                    } label: {
                        Label("Reglas", systemImage: "ruler.fill")
                    }
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Configuración", systemImage: "gearshape.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Más opciones del contexto")
            }
        }
    }

    /// Empty toolbar content para gating del personal sin warnings.
    private struct EmptyToolbarContent: ToolbarContent {
        var body: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) { EmptyView() }
        }
    }

    @ViewBuilder
    private func quickActionsMenu(actions: [AvailableAction]) -> some View {
        // P0 fix 2026-06-08 — acciones agrupadas por descriptor.section.
        // Apple HIG: Menu con Sections para clusters semánticos
        // (Crear / Registrar / Personas / Gobierno / ...). Orden estable por
        // section priority + label alfabético dentro de cada section.
        let grouped = Dictionary(grouping: actions, by: { $0.section })
        let orderedSections = grouped.keys.sorted(by: { contextActionSectionOrder($0) < contextActionSectionOrder($1) })

        Menu {
            ForEach(orderedSections, id: \.self) { sectionKey in
                if let sectionActions = grouped[sectionKey], !sectionActions.isEmpty {
                    Section(contextActionSectionLabel(sectionKey)) {
                        ForEach(sectionActions.sorted(by: { $0.label < $1.label })) { action in
                            // P0.5 — componente canónico: una acción disabled muestra su
                            // reason como subtitle del menu item.
                            ActionMenuButton(action: action) {
                                quickActionsRouter.open(ActionRouter.destination(for: action, in: .context(context.id)))
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .accessibilityLabel("Acciones del contexto")
    }

    /// Orden estable de sections del context_detail_descriptor.actions.
    /// Lower number = higher priority (aparece primero en el Menu).
    private func contextActionSectionOrder(_ section: String) -> Int {
        switch section {
        case "create", "creation":    return 0
        case "money", "monetary":     return 1
        case "people", "members":     return 2
        case "governance", "rules":   return 3
        case "events", "calendar":    return 4
        case "resources":             return 5
        case "documents":             return 6
        case "subcontexts", "children": return 7
        case "settings":              return 9
        default:                      return 8
        }
    }

    /// Friendly label para secciones del Menu.
    private func contextActionSectionLabel(_ section: String) -> String {
        switch section {
        case "create", "creation":     return "Crear"
        case "money", "monetary":      return "Dinero"
        case "people", "members":      return "Personas"
        case "governance":             return "Gobierno"
        case "rules":                  return "Reglas"
        case "events", "calendar":     return "Eventos"
        case "resources":              return "Recursos"
        case "documents":              return "Documentos"
        case "subcontexts", "children": return "Espacios hijos"
        case "settings":               return "Configuración"
        default:                       return section.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
