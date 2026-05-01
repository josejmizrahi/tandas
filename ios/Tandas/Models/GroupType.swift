import Foundation

enum GroupType: String, Codable, Sendable, CaseIterable, Identifiable {
    case recurringDinner = "recurring_dinner"
    case tandaSavings = "tanda_savings"
    case sportsTeam = "sports_team"
    case studyGroup = "study_group"
    case band, poker, family, travel, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recurringDinner: "Cena recurrente"
        case .tandaSavings:    "Tanda de ahorro"
        case .sportsTeam:      "Equipo deportivo"
        case .studyGroup:      "Grupo de estudio"
        case .band:            "Banda"
        case .poker:           "Poker night"
        case .family:          "Familia"
        case .travel:          "Viajes"
        case .other:           "Otro"
        }
    }

    var copy: String {
        switch self {
        case .recurringDinner: "Cena semanal o mensual con anfitrión rotativo"
        case .tandaSavings:    "Pool rotatorio de ahorro"
        case .sportsTeam:      "Partido semanal con posiciones"
        case .studyGroup:      "Club de lectura, jevruta, etc."
        case .band:            "Ensemble musical o creativo"
        case .poker:           "Noche de juego con pots"
        case .family:          "Comidas de domingo, fiestas"
        case .travel:          "Grupo de viajes con fondo común"
        case .other:           "Define el tuyo"
        }
    }

    var symbolName: String {
        switch self {
        case .recurringDinner: "fork.knife"
        case .tandaSavings:    "dollarsign.circle"
        case .sportsTeam:      "figure.run"
        case .studyGroup:      "book.closed"
        case .band:            "music.note"
        case .poker:           "suit.spade"
        case .family:          "house"
        case .travel:          "airplane"
        case .other:           "square.grid.2x2"
        }
    }

    var hasRecurringDefaults: Bool {
        switch self {
        case .recurringDinner, .sportsTeam, .studyGroup, .poker, .family, .travel: true
        case .tandaSavings, .band, .other: false
        }
    }

    var defaultEventLabel: String {
        switch self {
        case .recurringDinner: "Cena"
        case .tandaSavings:    "Tanda"
        case .sportsTeam:      "Partido"
        case .studyGroup:      "Sesión"
        case .band:            "Ensayo"
        case .poker:           "Mesa"
        case .family:          "Comida"
        case .travel:          "Viaje"
        case .other:           "Evento"
        }
    }
}
