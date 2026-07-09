import SwiftUI
import RuulCore

// MARK: - Hero (R.11.A — rich hero via RuulDetailHero, founder firmado 2026-06-16)
//
// R.11.A reemplaza el Hero minimal de R.10.E.8 (sólo chip "X pendientes")
// por el componente canónico RuulDetailHero — el mismo Hero que viven en
// Resource/Document/Decision/Obligation Detail. Doctrina R.5V §0.2:
// "Context/Resource/Document/Decision Detail van a terminar necesitando el
// mismo encabezado." El Hero de Context Home ahora se ve igual que el de
// cualquier Detail.
//
// Estructura:
//   icon · displayName · subtypeLabel  [subtype chip] [N miembros] [role]
//
// Pendientes ya no viven aquí — la Section "Atención" los muestra
// prominentes con priorities y acciones. Aquí el Hero es identidad pura.
//
// Personal context: subtitle simple, sin chips.

struct ContextDetailV2HeroSection: View {
    let context: AppContext
    let descriptor: ContextDetailDescriptor

    var body: some View {
        Section {
            RuulDetailHero(
                title: context.displayName,
                subtitle: subtitleText,
                systemImage: context.symbolName,
                tint: heroTint,
                status: nil,
                chips: chips
            )
            .ruulHeroRow()
        }
    }

    // MARK: - Computed

    private var subtitleText: String? {
        if context.isPersonal {
            return "Tu actividad, recursos y compromisos"
        }
        return subtypeLabel(context.subtype)
    }

    private var heroTint: Color {
        if context.isPersonal { return Theme.Tint.primary }
        switch context.subtype {
        case "family":       return Theme.Tint.success
        case "trip":         return Theme.Tint.info
        case "company":      return Theme.Tint.primary
        case "trust":        return .purple
        case "community":    return Theme.Tint.info
        case "project":      return Theme.Tint.warning
        case "friend_group": return Theme.Tint.primary
        default:             return Theme.Tint.primary
        }
    }

    private var chips: [RuulHeroChip] {
        guard !context.isPersonal else { return [] }
        var out: [RuulHeroChip] = []
        if context.memberCount > 1 {
            out.append(RuulHeroChip("\(context.memberCount) miembros"))
        }
        if let role = primaryRoleLabel {
            out.append(RuulHeroChip(role))
        }
        return out
    }

    private var primaryRoleLabel: String? {
        guard let role = context.roles.first else { return nil }
        switch role {
        case "admin":    return "Admin"
        case "founder":  return "Fundador"
        case "member":   return "Miembro"
        case "guest":    return "Invitado"
        case "observer": return "Observador"
        default:         return role.capitalized
        }
    }

    private func subtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo de amigos"
        case "company":      return "Empresa"
        default:             return "Grupo"
        }
    }
}
