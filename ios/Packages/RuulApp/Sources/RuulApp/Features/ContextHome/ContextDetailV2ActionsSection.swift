import SwiftUI
import RuulCore

// MARK: - Acciones rápidas (R.10.D + R.10.E.7 founder firmado 2026-06-15)
//
// Founder feedback: "completa el toolbar arreglalo. Necesito que esté perfecto
// y que se pueda hacer todo tipo de acciones del contexto."
//
// Esta Section materializa todas las acciones disponibles del contexto en el
// body, NO solo en el toolbar `+` Menu. Discoverability win: las acciones se
// ven sin abrir el Menu. El toolbar sigue siendo el atajo compacto siempre
// presente.
//
// Doctrina:
//   - Solo acciones `enabled` del descriptor.actions
//   - Agrupadas por section (Crear / Personas / Dinero / Eventos / Gobierno /
//     Recursos / Documentos / Espacios hijos) — mismo orden que el toolbar
//   - Header trailing "Más opciones" con chevron → expande/colapsa
//     (estado local) cuando hay > 4 acciones; si hay 4 o menos, todas
//     visibles
//   - Tap = mismo flujo que el toolbar (handleQuickAction via router)
//   - Disabled actions: no se muestran en el body (sólo en el toolbar
//     donde ActionMenuButton maneja el reason subtitle)

struct ContextDetailV2ActionsSection: View {
    let context: AppContext
    let actions: [AvailableAction]
    let router: NoopActionRouter

    @State private var isExpanded = false

    /// Acciones priorizadas para mostrar siempre (high-frequency).
    private let highFrequencyKeys: Set<String> = [
        "record_expense",
        "create_event",
        "create_decision",
        "invite_member"
    ]

    var body: some View {
        let enabled = actions.filter { $0.enabled }
        if !enabled.isEmpty {
            // Agrupar por section, ordenado por priority (mismo orden que toolbar).
            let grouped = Dictionary(grouping: enabled, by: { $0.section })
            let orderedSections = grouped.keys.sorted(by: {
                contextActionSectionOrder($0) < contextActionSectionOrder($1)
            })

            // Si hay <=4 acciones, mostrarlas todas. Si hay más, mostrar las
            // high-frequency + "Más opciones" expandible.
            let prioritized = enabled.filter { highFrequencyKeys.contains($0.actionKey) }
                .sorted(by: { $0.label < $1.label })
            let rest = enabled.filter { !highFrequencyKeys.contains($0.actionKey) }
                .sorted(by: { $0.label < $1.label })

            Section {
                if enabled.count <= 4 || isExpanded {
                    // Mostrar todas las acciones agrupadas por section.
                    ForEach(orderedSections, id: \.self) { sectionKey in
                        if let sectionActions = grouped[sectionKey], !sectionActions.isEmpty {
                            ForEach(sectionActions.sorted(by: { $0.label < $1.label })) { action in
                                actionRow(action)
                            }
                        }
                    }
                } else {
                    // Mostrar high-frequency arriba, "Más opciones" abajo.
                    ForEach(prioritized) { action in
                        actionRow(action)
                    }
                    if !rest.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = true
                            }
                        } label: {
                            HStack {
                                Label("Más opciones", systemImage: "ellipsis.circle")
                                    .foregroundStyle(Theme.Text.primary)
                                Spacer()
                                Text("\(rest.count)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(Theme.Text.secondary)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Acciones rápidas")
                    Spacer()
                    if isExpanded && enabled.count > 4 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = false
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text("Mostrar menos")
                                Image(systemName: "chevron.up")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: AvailableAction) -> some View {
        let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
        Button {
            router.open(ActionRouter.destination(for: action, in: .context(context.id)))
        } label: {
            Label {
                Text(action.label)
                    .foregroundStyle(Theme.Text.primary)
            } icon: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(Theme.Tint.primary)
            }
        }
    }

    /// Mismo orden de section priority que el toolbar (ContextDetailV2Toolbar).
    private func contextActionSectionOrder(_ section: String) -> Int {
        switch section {
        case "create", "creation":     return 0
        case "money", "monetary":      return 1
        case "people", "members":      return 2
        case "governance", "rules":    return 3
        case "events", "calendar":     return 4
        case "resources":              return 5
        case "documents":              return 6
        case "subcontexts", "children": return 7
        case "settings":               return 9
        default:                       return 8
        }
    }
}
