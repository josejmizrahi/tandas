import SwiftUI
import RuulCore

// MARK: - 1. Hero (R.5V — RuulDetailHero canónico)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailHeroSection: View {
    let event: CalendarEvent
    let context: AppContext
    let store: EventDetailStore

    var body: some View {
        Section {
            RuulDetailHero(
                title: event.title,
                subtitle: heroSubtitle(event),
                systemImage: event.type.symbolName,
                tint: Theme.Tint.primary,
                status: heroStatus(event),
                chips: heroChips(event)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroSubtitle(_ event: CalendarEvent) -> String? {
        EventDetailFormatting.headerDateTimeLine(event) ?? context.displayName
    }

    /// Doctrina §0.2 — el Hero lleva identidad + estado. Para eventos agendados
    /// el badge "Activo" sería ruido (la zona de acción principal ya comunica
    /// el estado vivo); solo los estados terminales se muestran arriba.
    private func heroStatus(_ event: CalendarEvent) -> RuulStatusBadge.State? {
        let state = RuulStatusBadge.State.event(event.status)
        return state == .active ? nil : state
    }

    /// Chips del Hero — text-only (RuulDetailHero los renderiza como pills).
    /// Tipo, ubicación, recurrencia, número de sesión, asistentes summary.
    private func heroChips(_ event: CalendarEvent) -> [String] {
        var chips: [String] = [event.type.label]
        if event.isVirtual {
            chips.append("Virtual")
        } else if let location = event.locationText, !location.isEmpty {
            chips.append(location)
        } else if EventDetailFormatting.isLocationUndecided(event) {
            // R.5V.3A.event.fix — sin location + no virtual: label dinámico
            // según recurrencia (weekly rota host → "Por anfitrión").
            chips.append(EventDetailFormatting.undecidedLocationLabel(event))
        }
        if event.isRecurring {
            chips.append(EventDetailFormatting.recurrenceLabel(event))
        }
        if let total = event.recurrenceCount {
            chips.append("Sesión \(event.occurrenceNumber) de \(total)")
        }
        chips.append(participantSummary())
        return chips
    }

    /// "12 asistentes" — total de invitados al evento. Si el contexto es
    /// personal o aún no hay invitados, se ajusta.
    private func participantSummary() -> String {
        let total = store.participants.count
        if total == 0 { return "Aún sin invitados" }
        return "\(total) \(total == 1 ? "asistente" : "asistentes")"
    }
}
