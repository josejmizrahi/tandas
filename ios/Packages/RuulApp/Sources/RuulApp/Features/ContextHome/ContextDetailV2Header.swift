import SwiftUI
import RuulCore

// MARK: - Hero (R.5V.3A)

struct ContextDetailV2HeroSection: View {
    let context: AppContext
    let descriptor: ContextDetailDescriptor

    var body: some View {
        let d = descriptor
        // Fase 9.3 (founder feedback 2026-06-14) — antes el Hero tenía
        // avatar enorme + nombre + subtitle + chips, ocupando ~140px de
        // pantalla. El nombre ya está en el toolbar (title del nav), así
        // que aquí solo dejamos los chips de métricas en una fila
        // compacta. Hero reducido a ~50px.
        Section {
            HStack(spacing: 8) {
                ForEach(heroChips(d.metrics), id: \.self) { chip in
                    Text(chip)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(Theme.Tint.primary)
                        .background(Theme.Tint.primary.badgeFillSubtle, in: Capsule())
                        .lineLimit(1)
                }
                if context.isPersonal {
                    Text(heroSubtitle(d) ?? "")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
