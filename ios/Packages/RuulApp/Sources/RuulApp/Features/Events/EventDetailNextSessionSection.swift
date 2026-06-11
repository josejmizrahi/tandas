import SwiftUI
import RuulCore

// MARK: - F.EVENT.8 Próxima reunión (Section dedicada)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailNextSessionSection: View {
    let event: CalendarEvent
    let store: EventDetailStore

    var body: some View {
        if event.isRecurring && event.isScheduled {
            if EventDetailFormatting.isLastSession(event) {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Última sesión de la serie")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            if let total = event.recurrenceCount {
                                Text("Sesión \(event.occurrenceNumber) de \(total). Al cerrar este evento la serie termina.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            } else if let until = event.recurrenceUntil {
                                Text("La serie termina al pasar el \(until.formatted(date: .abbreviated, time: .omitted)).")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "flag.checkered")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            } else if let preview = store.nextHostPreview,
                      let hostName = preview.nextActorName,
                      let nextStart = EventDetailFormatting.nextOccurrenceDate(for: event) {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Organiza \(hostName)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(nextStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.2.crop.square.stack.fill")
                            .foregroundStyle(Theme.Tint.primary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Próxima reunión")
                        if preview.isOverride {
                            Text("· Definido manualmente")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        }
    }
}
