import SwiftUI
import RuulCore

// MARK: - Hero (R.5V.3A)

struct ContextDetailV2HeroSection: View {
    let context: AppContext
    let descriptor: ContextDetailDescriptor

    var body: some View {
        let d = descriptor
        Section {
            RuulDetailHero(
                title: context.isPersonal ? "Mi espacio" : (d.contextDisplayName ?? context.displayName),
                subtitle: heroSubtitle(d),
                systemImage: context.symbolName,
                tint: Theme.Tint.primary,
                chips: heroChips(d.metrics)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroSubtitle(_ d: ContextDetailDescriptor) -> String? {
        if context.isPersonal { return "Tu actividad, recursos y compromisos" }
        return contextSubtypeLabel(context.subtype)
    }

    private func contextSubtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo"
        case "company":      return "Empresa"
        default:             return subtype.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func heroChips(_ m: ContextMetrics) -> [String] {
        var chips: [String] = []
        if m.memberCount > 0 {
            chips.append("\(m.memberCount) \(m.memberCount == 1 ? "miembro" : "miembros")")
        }
        let resourceTotal = m.resourceCountByClass.values.reduce(0, +)
        if resourceTotal > 0 {
            chips.append("\(resourceTotal) \(resourceTotal == 1 ? "recurso" : "recursos")")
        }
        let pending = m.openObligations + m.pendingDecisions
        if pending > 0 {
            chips.append("\(pending) \(pending == 1 ? "pendiente" : "pendientes")")
        }
        return chips
    }
}
