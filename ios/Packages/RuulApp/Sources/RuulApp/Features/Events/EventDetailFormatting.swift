import SwiftUI
import RuulCore

// MARK: - Helpers compartidos del Event Detail
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo). Funciones puras usadas por varias Sections del detalle.

enum EventDetailFormatting {
    static func headerDateLine(_ date: Date) -> String {
        let dayMonth = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(dayMonth.capitalizedFirstLetter) · \(time)"
    }

    /// "Viernes 5 de junio · 19:00 – 22:00" — variante del header que incluye
    /// la hora de fin cuando `ends_at` existe (Apple Calendar muestra siempre
    /// el rango completo, no solo el inicio).
    static func headerDateTimeLine(_ event: CalendarEvent) -> String? {
        guard let starts = event.startsAt else { return nil }
        let dayMonth = starts.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirstLetter
        guard let range = timeRangeLine(event) else { return dayMonth }
        return "\(dayMonth) · \(range)"
    }

    /// "Viernes 5 de junio de 2026" — fecha completa para la Info row.
    static func infoDateLine(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()).capitalizedFirstLetter
    }

    /// "19:00 – 22:00" (mismo día), "19:00 – 6 jun, 2:00" (cruza medianoche)
    /// o "19:00" si no hay hora de fin.
    static func timeRangeLine(_ event: CalendarEvent) -> String? {
        guard let starts = event.startsAt else { return nil }
        let startTime = starts.formatted(date: .omitted, time: .shortened)
        guard let ends = event.endsAt, ends > starts else { return startTime }
        let endLabel = Calendar.current.isDate(starts, inSameDayAs: ends)
            ? ends.formatted(date: .omitted, time: .shortened)
            : ends.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "\(startTime) – \(endLabel)"
    }

    /// "3 h, 30 min" — duración del evento cuando hay hora de fin.
    static func durationLabel(_ event: CalendarEvent) -> String? {
        guard let starts = event.startsAt, let ends = event.endsAt, ends > starts else { return nil }
        return Duration.seconds(ends.timeIntervalSince(starts))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func recurrenceLabel(_ event: CalendarEvent) -> String {
        guard let raw = event.recurrenceRule?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return "Recurrente" }
        // F.EVENT.6 — soporta tanto los simples "weekly"/"daily"/... como
        // RRULE-style "freq=weekly"/...
        if raw == "weekly"  || raw.contains("freq=weekly")  { return "Semanal" }
        if raw == "daily"   || raw.contains("freq=daily")   { return "Diaria" }
        if raw == "monthly" || raw.contains("freq=monthly") { return "Mensual" }
        if raw == "yearly"  || raw.contains("freq=yearly")  { return "Anual" }
        return "Recurrente"
    }

    /// R.5V.3A.event.fix — evento sin ubicación fija (host rota o lugar TBD).
    static func isLocationUndecided(_ event: CalendarEvent) -> Bool {
        !event.isVirtual && (event.locationText ?? "").isEmpty
    }

    /// Label del fallback según recurrencia: weekly → "Por anfitrión"
    /// (rotación real), cualquier otra → "Por definir".
    static func undecidedLocationLabel(_ event: CalendarEvent) -> String {
        event.isRecurring && recurrenceLabel(event) == "Semanal"
            ? "Por anfitrión"
            : "Por definir"
    }

    /// Variante más explícita para la Info row.
    static func undecidedLocationFullLabel(_ event: CalendarEvent) -> String {
        event.isRecurring && recurrenceLabel(event) == "Semanal"
            ? "Lo define el anfitrión"
            : "Por definir"
    }

    /// Calcula la fecha de la próxima ocurrencia client-side a partir del
    /// `starts_at` actual + la frecuencia. El backend hace lo mismo en
    /// `close_event`; acá lo replicamos sólo para mostrar — la verdad sigue
    /// siendo del backend al cerrar.
    static func nextOccurrenceDate(for event: CalendarEvent) -> Date? {
        guard let starts = event.startsAt,
              let rule = event.recurrenceRule?.lowercased() else { return nil }
        let calendar = Calendar.current
        if rule == "weekly" || rule.contains("freq=weekly") {
            return calendar.date(byAdding: .day, value: 7, to: starts)
        }
        if rule == "daily" || rule.contains("freq=daily") {
            return calendar.date(byAdding: .day, value: 1, to: starts)
        }
        if rule == "monthly" || rule.contains("freq=monthly") {
            return calendar.date(byAdding: .month, value: 1, to: starts)
        }
        if rule == "yearly" || rule.contains("freq=yearly") {
            return calendar.date(byAdding: .year, value: 1, to: starts)
        }
        return nil
    }

    /// `true` cuando cerrar este evento NO va a crear una siguiente ocurrencia
    /// por alguno de los bounds (count alcanzado o next_start excede until).
    /// Espejea la lógica de `close_event` en el backend.
    static func isLastSession(_ event: CalendarEvent) -> Bool {
        if let total = event.recurrenceCount, event.occurrenceNumber >= total {
            return true
        }
        if let until = event.recurrenceUntil, let nextStart = nextOccurrenceDate(for: event),
           nextStart > until {
            return true
        }
        return false
    }

    /// El evento ya inició (o está por iniciar en breve).
    static func shouldShowCheckIn(_ event: CalendarEvent) -> Bool {
        guard let starts = event.startsAt else { return false }
        return Date() >= starts.addingTimeInterval(-30 * 60)
    }
}

private extension String {
    /// "viernes 5 de junio" → "Viernes 5 de junio" (locale es_MX usa minúscula
    /// para los días por default).
    var capitalizedFirstLetter: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
