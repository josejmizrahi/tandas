import SwiftUI
import RuulCore

// MARK: - Descripción del evento (notas del organizador)
//
// Apple Calendar muestra las notas del evento en sección propia. `description`
// es opcional — si viene vacía la sección se omite sin alterar el orden del
// scroll (doctrina R.5V §0.2).

struct EventDetailDescriptionSection: View {
    let event: CalendarEvent

    var body: some View {
        if let text = trimmedDescription {
            Section {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
            } header: {
                Text("Descripción")
            }
        }
    }

    private var trimmedDescription: String? {
        guard let raw = event.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }
}
