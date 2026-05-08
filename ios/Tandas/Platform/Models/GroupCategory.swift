import Foundation
import RuulUI

/// Categoría del grupo, deriva del template. Se persiste en `groups.category`
/// (Fase 2 agrega el campo backend). Hoy se infiere por nombre del template
/// hasta que Fase 2 lo migre.
///
/// Per DS v3 §4.7: el color del avatar es **automático según categoría**.
/// NO se puede customizar por founder.
public enum GroupCategory: String, Sendable, CaseIterable, Codable, Hashable {
    case socialRecurring        // Cenas recurrentes, clubes de lectura, tertulias
    case sharedResource         // Palcos, cabañas, yates, suscripciones
    case rotatingSavings        // Tandas, susu, hui, vaquitas
    case patrimonialFamily      // Consejos familiares, herencias
    case amateurTeam            // Bandas, equipos deportivos
    case groupTravel            // Squad trips, retreats, viajes
    case religiousCultural      // Comunidades religiosas, hermandades
    case professionalInformal   // Cooperativas, mastermind, partnerships
    case digitalCommunity       // Servidores Discord, mod teams
    case commitmentPact         // Pactos de fitness, productividad

    /// Nombre user-facing de la categoría (en español).
    public var displayName: String {
        switch self {
        case .socialRecurring:      return "Social recurrente"
        case .sharedResource:       return "Recurso compartido"
        case .rotatingSavings:      return "Ahorro rotativo"
        case .patrimonialFamily:    return "Patrimonio familiar"
        case .amateurTeam:          return "Equipo amateur"
        case .groupTravel:          return "Viaje grupal"
        case .religiousCultural:    return "Comunidad religiosa"
        case .professionalInformal: return "Profesional informal"
        case .digitalCommunity:     return "Comunidad digital"
        case .commitmentPact:       return "Pacto de compromiso"
        }
    }

    /// Color ramp asociado per DS §4.7 (mapping fijo, no customizable).
    public var ramp: GroupColorRamp {
        switch self {
        case .socialRecurring:      return .teal
        case .sharedResource:       return .blue
        case .rotatingSavings:      return .purple
        case .patrimonialFamily:    return .amber
        case .amateurTeam:          return .green
        case .groupTravel:          return .coral
        case .religiousCultural:    return .pink
        case .professionalInformal: return .gray
        case .digitalCommunity:     return .blue
        case .commitmentPact:       return .green
        }
    }
}
