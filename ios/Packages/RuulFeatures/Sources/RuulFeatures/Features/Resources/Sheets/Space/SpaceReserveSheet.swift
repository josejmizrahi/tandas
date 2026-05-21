import SwiftUI
import RuulUI
import RuulCore

/// "Reservar" sheet for the Space detail surface. V1 placeholder: the
/// full booking persistence path (slot-of-this-space + `book_slot` RPC)
/// hasn't landed yet, so this sheet captures intent and explains the
/// feature is on the way. Form fields are real (date / time / duration)
/// so the design is unblocked for screenshots and onboarding flows; the
/// "Reservar" button is disabled with a clear inline note.
public struct SpaceReserveSheet: View {
    @Environment(\.dismiss) private var dismiss

    let resourceName: String

    @State private var date: Date = .now
    @State private var startTime: Date = .now
    @State private var durationHours: Int = 2

    public init(resourceName: String) {
        self.resourceName = resourceName
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Reservar \(resourceName)") {
                    DatePicker("Fecha", selection: $date, displayedComponents: .date)
                    DatePicker("Hora de inicio", selection: $startTime, displayedComponents: .hourAndMinute)
                    Stepper("Duración: \(durationHours) h", value: $durationHours, in: 1...12)
                }
                Section {
                    Label("Las reservas con confirmación automática llegan en V1.5. Por ahora coordínalo en el chat del grupo.", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .navigationTitle("Reservar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
