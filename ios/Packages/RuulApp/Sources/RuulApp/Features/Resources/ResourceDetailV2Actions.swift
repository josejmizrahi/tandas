import SwiftUI
import RuulCore

/// R.10.A — Toolbar "+" Menu con acciones descriptor-driven (code move,
/// zero behavior change).
///
/// Doctrina: R.5V native-first.
/// Movido del monolito previo (894–992).
///
/// 2026-06-08 founder option B — todas las acciones del recurso viven en el
/// "+" del toolbar agrupadas por section semántica. Apple Wallet/Stocks-ish:
/// el Detail muestra info, las acciones viven en el toolbar.

struct ResourceDetailV2ActionsMenu: View {
    let actions: [ResourceDescriptorAction]
    let onTap: (ResourceDescriptorAction) -> Void

    var body: some View {
        let enabledActions = actions.filter { $0.enabled }
        if !enabledActions.isEmpty {
            let grouped = Dictionary(grouping: enabledActions, by: { $0.section })
            let orderedSections = grouped.keys.sorted(by: {
                ResourceDetailV2ActionsCopy.sectionOrder($0) < ResourceDetailV2ActionsCopy.sectionOrder($1)
            })

            Menu {
                ForEach(orderedSections, id: \.self) { sectionKey in
                    if let sectionActions = grouped[sectionKey], !sectionActions.isEmpty {
                        Section(ResourceDetailV2ActionsCopy.sectionLabel(sectionKey)) {
                            ForEach(sectionActions.sorted(by: { $0.label < $1.label })) { action in
                                let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
                                if action.dangerous {
                                    Button(role: .destructive) {
                                        onTap(action)
                                    } label: {
                                        Label(action.label, systemImage: presentation.symbolName)
                                    }
                                } else {
                                    Button {
                                        onTap(action)
                                    } label: {
                                        Label(action.label, systemImage: presentation.symbolName)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Acciones del recurso")
        }
    }
}

/// Helpers de copy/orden para sections del Menu. Snapshot estático puro.
enum ResourceDetailV2ActionsCopy {
    /// Orden estable de sections del resource_detail_descriptor.actions.
    static func sectionOrder(_ section: String) -> Int {
        switch section {
        case "general":      return 0
        case "ownership":    return 1
        case "rights":       return 2
        case "documents":    return 3
        case "reservations": return 4
        case "monetary",
             "money":        return 5
        case "maintenance":  return 6
        case "relations":    return 7
        case "settings":     return 9
        default:             return 8
        }
    }

    /// Friendly label para sections del Menu.
    static func sectionLabel(_ section: String) -> String {
        switch section {
        case "general":      return "General"
        case "ownership":    return "Propiedad"
        case "rights":       return "Permisos"
        case "documents":    return "Documentos"
        case "reservations": return "Reservaciones"
        case "monetary", "money": return "Dinero"
        case "maintenance":  return "Mantenimiento"
        case "relations":    return "Relaciones"
        case "settings":     return "Configuración"
        default:             return section.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
