import SwiftUI
import RuulCore

// MARK: - Serie (navegación entre ocurrencias reales)
//
// F.EVENT.8 — `previous_event_id` / `next_event_id` encadenan las ocurrencias
// ya creadas de la serie. Igual que Calendar: el usuario salta entre sesiones
// sin volver a la lista. Para eventos sueltos (ambos nil) la sección se omite.
//
// No confundir con "Próxima reunión" (EventDetailNextSessionSection): esa
// muestra el *preview* del próximo host antes de que la ocurrencia exista;
// esta navega a ocurrencias que ya son filas reales en calendar_events.

struct EventDetailSeriesSection: View {
    let event: CalendarEvent
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        if event.previousEventId != nil || event.nextEventId != nil {
            Section {
                if let previousId = event.previousEventId {
                    NavigationLink {
                        EventDetailView(eventId: previousId, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sesión anterior")
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                Text(sessionLabel(event.occurrenceNumber - 1))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.backward.circle.fill")
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }
                if let nextId = event.nextEventId {
                    NavigationLink {
                        EventDetailView(eventId: nextId, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Siguiente sesión")
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                Text(sessionLabel(event.occurrenceNumber + 1))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.forward.circle.fill")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Serie")
            }
        }
    }

    private func sessionLabel(_ number: Int) -> String {
        guard number > 0 else { return "Serie" }
        if let total = event.recurrenceCount {
            return "Sesión \(number) de \(total)"
        }
        return "Sesión \(number)"
    }
}
