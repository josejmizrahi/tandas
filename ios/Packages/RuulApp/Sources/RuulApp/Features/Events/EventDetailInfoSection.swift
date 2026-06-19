import SwiftUI
import RuulCore

// MARK: - 6. Información (LabeledContent nativo)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailInfoSection: View {
    let event: CalendarEvent
    let context: AppContext
    let store: EventDetailStore
    let isHost: Bool

    var body: some View {
        Section {
            LabeledContent("Organizador") {
                Text(store.displayName(for: event.hostActorId) + (isHost ? " (tú)" : ""))
                    .foregroundStyle(Theme.Text.primary)
                    .multilineTextAlignment(.trailing)
            }
            if let starts = event.startsAt {
                LabeledContent("Fecha") {
                    Text(EventDetailFormatting.infoDateLine(starts))
                        .multilineTextAlignment(.trailing)
                }
                if let range = EventDetailFormatting.timeRangeLine(event) {
                    LabeledContent("Horario") {
                        Text(range)
                    }
                }
                if let duration = EventDetailFormatting.durationLabel(event) {
                    LabeledContent("Duración") {
                        Text(duration)
                    }
                }
            }
            LabeledContent("Tipo") {
                Text(event.type.label)
            }
            if event.isVirtual {
                LabeledContent("Ubicación") {
                    Text("Virtual")
                }
            } else if let location = event.locationText, !location.isEmpty {
                LabeledContent("Ubicación") {
                    Text(location)
                        .multilineTextAlignment(.trailing)
                }
            } else if EventDetailFormatting.isLocationUndecided(event) {
                LabeledContent("Ubicación") {
                    Text(EventDetailFormatting.undecidedLocationFullLabel(event))
                        .foregroundStyle(Theme.Text.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if event.isRecurring {
                LabeledContent("Repetición") {
                    Text(EventDetailFormatting.recurrenceLabel(event))
                }
            }
            if let total = event.recurrenceCount {
                LabeledContent("Serie") {
                    Text("\(event.occurrenceNumber) de \(total)")
                }
            }
            if let until = event.recurrenceUntil {
                // "Fin de la serie" — no confundir con la hora de fin del
                // evento (row "Horario" arriba).
                LabeledContent("Fin de la serie") {
                    Text(until.formatted(date: .abbreviated, time: .omitted))
                }
            }
            LabeledContent("Espacio") {
                Text(context.displayName)
                    .multilineTextAlignment(.trailing)
            }
            if let created = event.createdAt {
                LabeledContent("Creado") {
                    Text(created.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } header: {
            Text("Información")
        }
    }
}
