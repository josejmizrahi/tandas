import SwiftUI
import CoreLocation
import RuulCore

// MARK: - 2. Acción principal (zona dinámica)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailPrimaryActionSection: View {
    let event: CalendarEvent
    let store: EventDetailStore
    let runner: ActionRunner
    let myActorId: UUID?
    let eventId: UUID
    let context: AppContext
    /// Acción "Llegué" — la ejecuta el parent (setea notice + recarga actividad).
    let onSelfCheckIn: () async -> Void

    /// Check-in por ubicación foreground (founder feedback 2026-06-20).
    /// Solo se activa cuando `event.hasGeoCoordinates`. El service tolera
    /// permiso denegado en silencio — caemos al CTA manual de siempre.
    @State private var proximity = LocationProximityService()

    /// Umbral en metros para considerar "estoy en el lugar". 200m balance
    /// entre precisión GPS típica iPhone (~10-30m al aire libre, peor en
    /// edificios) y eventos en domicilios o restaurants donde el centro
    /// MapKit puede caer fuera del local exacto.
    private let proximityThresholdMeters: CLLocationDistance = 200

    private enum PrimaryState {
        /// Evento ya no está activo (closed / cancelled).
        case ended(label: String, symbol: String, tint: Color)
        /// Hice check-in.
        case checkedIn(at: Date?)
        /// Evento en curso o por iniciar — puedo registrar llegada.
        case canCheckIn
        /// Ya respondí (going/maybe/declined) — sigue activo.
        case responded(status: String)
        /// Aún no he respondido.
        case needsResponse
    }

    private func primaryState(_ event: CalendarEvent) -> PrimaryState {
        if event.isCompleted {
            return .ended(label: "Evento finalizado", symbol: "checkmark.seal.fill", tint: .gray)
        }
        if !event.isScheduled {
            return .ended(label: "Evento cancelado", symbol: "xmark.circle.fill", tint: .red)
        }
        let mine = store.myParticipation(myActorId: myActorId)
        if mine?.checkedIn == true {
            return .checkedIn(at: mine?.checkedInAt)
        }
        if mine?.status == "cancelled" {
            return .ended(label: "Cancelaste asistencia", symbol: "xmark.circle.fill", tint: .red)
        }
        if EventDetailFormatting.shouldShowCheckIn(event) && mine?.status != "declined" {
            return .canCheckIn
        }
        if let status = mine?.status, ["going", "maybe", "declined"].contains(status) {
            return .responded(status: status)
        }
        return .needsResponse
    }

    var body: some View {
        switch primaryState(event) {
        case .ended(let label, let symbol, let tint):
            Section {
                Label {
                    Text(label).font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
        case .checkedIn(let when):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Registraste tu llegada")
                            .font(.callout.weight(.semibold))
                        if let when {
                            Text(when.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                        .symbolEffect(.bounce, value: when)
                }
            }
        case .canCheckIn:
            checkInSection
        case .needsResponse:
            rsvpSection(heading: "Responde tu asistencia", current: nil)
        case .responded(let status):
            rsvpSection(heading: respondedHeading(status), current: status)
        }
    }

    /// CTA "Llegué" — se enriquece con check-in por ubicación cuando el evento
    /// tiene coords (founder feedback 2026-06-20). Comportamiento:
    /// - Sin coords o sin permiso: botón "Llegué" normal.
    /// - Con coords + autorizado + lejos: botón normal + hint "A 1.2 km del
    ///   lugar" para que el usuario sepa por qué no se auto-activó.
    /// - Con coords + autorizado + cerca (<200m): label cambia a "Estoy aquí"
    ///   con location.fill icon + hint "Estás en el lugar" verde.
    /// El check-in mismo siempre es manual (no auto-trigger) — el usuario
    /// confirma con tap. El RPC backend que recibe el check-in es el mismo.
    @ViewBuilder
    private var checkInSection: some View {
        let isNear = isWithinProximity()
        Section {
            Button {
                Task { await onSelfCheckIn() }
            } label: {
                Label(
                    isNear ? "Estoy aquí · Llegué" : "Llegué",
                    systemImage: isNear ? "location.fill" : "checkmark.circle.fill"
                )
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .disabled(runner.isRunning)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } footer: {
            proximityFooter
        }
        .task {
            if event.hasGeoCoordinates {
                proximity.requestUpdates()
            }
        }
    }

    @ViewBuilder
    private var proximityFooter: some View {
        if event.hasGeoCoordinates {
            switch proximity.authorization {
            case .denied:
                // No ofender al usuario; el CTA manual sirve. Sin mensaje.
                EmptyView()
            case .undetermined:
                // Aún esperando primera respuesta. Sin mensaje.
                EmptyView()
            case .authorized:
                proximityReadingHint
            }
        }
    }

    @ViewBuilder
    private var proximityReadingHint: some View {
        if let lat = event.locationLat,
           let lng = event.locationLng,
           let distance = proximity.distance(to: lat, lng: lng) {
            if distance <= proximityThresholdMeters {
                Label("Estás en el lugar", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Tint.success)
            } else {
                Label(formattedDistance(distance), systemImage: "location")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } else if proximity.isUpdating {
            Label("Detectando tu ubicación…", systemImage: "location")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
        }
    }

    private func isWithinProximity() -> Bool {
        guard event.hasGeoCoordinates,
              proximity.authorization == .authorized,
              let lat = event.locationLat,
              let lng = event.locationLng,
              let d = proximity.distance(to: lat, lng: lng)
        else { return false }
        return d <= proximityThresholdMeters
    }

    /// "150 m" / "1.2 km del lugar". Apple-style measurement formatting.
    private func formattedDistance(_ d: CLLocationDistance) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 1
        let measurement = Measurement(value: d, unit: UnitLength.meters)
        return "A " + formatter.string(from: measurement) + " del lugar"
    }

    @ViewBuilder
    private func rsvpSection(heading: String, current: String?) -> some View {
        Section {
            rsvpSegmented(current: current)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
        } header: {
            Text(heading)
        } footer: {
            if let confirmation = responseConfirmation(current) {
                Text(confirmation)
            }
        }
    }

    /// Picker nativo iOS `.segmented` (UISegmentedControl). El binding es
    /// `RSVPStatus?` — cuando `current` es nil no hay segmento seleccionado.
    @ViewBuilder
    private func rsvpSegmented(current: String?) -> some View {
        let currentEnum: RSVPStatus? = current.flatMap { RSVPStatus(rawValue: $0) }
        Picker("Respuesta", selection: Binding<RSVPStatus?>(
            get: { currentEnum },
            set: { newValue in
                guard let newValue else { return }
                Task {
                    await runner.run {
                        try await store.rsvp(newValue, eventId: eventId, context: context)
                    }
                }
            }
        )) {
            Text("Voy").tag(RSVPStatus?.some(.going))
            Text("Tal vez").tag(RSVPStatus?.some(.maybe))
            Text("No voy").tag(RSVPStatus?.some(.declined))
        }
        .pickerStyle(.segmented)
        .disabled(runner.isRunning)
    }

    private func respondedHeading(_ status: String) -> String {
        switch status {
        case "going":    return "Vas a asistir"
        case "maybe":    return "Tal vez asistas"
        case "declined": return "No asistirás"
        default:         return "Tu respuesta"
        }
    }

    private func responseConfirmation(_ status: String?) -> String? {
        switch status {
        case "going":    return "Confirmaste tu asistencia."
        case "maybe":    return "Marcaste \"Tal vez\"."
        case "declined": return "No vas a este evento."
        default:         return nil
        }
    }
}
