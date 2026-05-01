import Foundation
import EventKit
import OSLog

/// Add-to-Calendar service. Two modes:
///
/// 1. **EKEvent (preferred)**: requests calendar write access, creates an
///    EKEvent in the user's default calendar with title + date + location +
///    URL + alarms. Returns the event's identifier so the caller can store
///    it (to remove later when RSVP changes).
///
/// 2. **`.ics` fallback**: generates an RFC 5545 calendar string and writes
///    it to a temp file. Returns the URL — caller presents it via
///    `UIDocumentInteractionController` or `ShareLink`. Works without any
///    calendar permission.
///
/// `EKEventStore` is expensive to instantiate; the service caches one
/// instance.
@MainActor
@Observable
final class CalendarExportService {
    enum AuthorizationStatus: Sendable, Hashable {
        case notDetermined, denied, granted, writeOnly, restricted
    }

    private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "calendar")
    private let store = EKEventStore()

    init() {
        refreshAuthorizationStatus()
    }

    private func refreshAuthorizationStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = mapStatus(status)
    }

    private func mapStatus(_ status: EKAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .denied:           return .denied
        case .restricted:       return .restricted
        case .fullAccess:       return .granted
        case .writeOnly:        return .writeOnly
        case .authorized:       return .granted   // legacy
        @unknown default:       return .notDetermined
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            refreshAuthorizationStatus()
            return granted
        } catch {
            log.warning("calendar auth request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Adds the event to the user's default calendar. Returns the EKEvent
    /// identifier on success — store this on the RSVP so you can remove
    /// the calendar event later if the user changes their RSVP.
    func addToCalendar(_ event: Event, vocabulary: String) async throws -> String {
        if authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
        }
        guard authorizationStatus == .granted || authorizationStatus == .writeOnly else {
            throw CalendarError.permissionDenied
        }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title.isEmpty ? vocabulary.capitalized : event.title
        ekEvent.startDate = event.startsAt
        ekEvent.endDate = event.resolvedEndsAt
        if let loc = event.locationName {
            ekEvent.location = loc
        }
        if let notes = event.description, !notes.isEmpty {
            ekEvent.notes = notes
        }
        ekEvent.url = URL(string: "ruul://event/\(event.id.uuidString)")
        ekEvent.calendar = store.defaultCalendarForNewEvents

        // Sensible defaults: 1 day before + 1 hour before alarms.
        ekEvent.addAlarm(EKAlarm(relativeOffset: -86_400))
        ekEvent.addAlarm(EKAlarm(relativeOffset: -3_600))

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            return ekEvent.eventIdentifier
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }

    /// Removes the previously-added EKEvent. No-op if the id no longer
    /// resolves (user already deleted it from Calendar).
    func removeFromCalendar(eventIdentifier: String) async throws {
        guard authorizationStatus == .granted || authorizationStatus == .writeOnly else {
            throw CalendarError.permissionDenied
        }
        guard let ekEvent = store.event(withIdentifier: eventIdentifier) else {
            return  // already deleted from Calendar — fine
        }
        do {
            try store.remove(ekEvent, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }

    /// Generates an RFC 5545 .ics file for sharing. No permission needed —
    /// returns a temp file URL that ShareLink / UIActivityViewController
    /// can present so the user picks Calendar themselves.
    func icsFileURL(for event: Event, vocabulary: String, hostName: String?) throws -> URL {
        let ics = makeICS(event: event, vocabulary: vocabulary, hostName: hostName)
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("ruul-\(event.id.uuidString.prefix(8)).ics")
        do {
            try ics.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }

    private func makeICS(event: Event, vocabulary: String, hostName: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: .now).replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let startStamp = icsTimestamp(event.startsAt)
        let endStamp = icsTimestamp(event.resolvedEndsAt)
        let summary = (event.title.isEmpty ? vocabulary.capitalized : event.title)
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
        let location = (event.locationName ?? "")
            .replacingOccurrences(of: ",", with: "\\,")
        let description = [
            event.description ?? "",
            hostName.map { "Host: \($0)" } ?? "",
            "Organizado por ruul"
        ].filter { !$0.isEmpty }.joined(separator: "\\n")

        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//ruul//iOS//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(event.id.uuidString)@ruul.app",
            "DTSTAMP:\(now)Z",
            "DTSTART:\(startStamp)Z",
            "DTEND:\(endStamp)Z",
            "SUMMARY:\(summary)",
            location.isEmpty ? "" : "LOCATION:\(location)",
            description.isEmpty ? "" : "DESCRIPTION:\(description)",
            "URL:ruul://event/\(event.id.uuidString)",
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "DESCRIPTION:\(summary)",
            "TRIGGER:-P1D",
            "END:VALARM",
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "DESCRIPTION:\(summary)",
            "TRIGGER:-PT1H",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR"
        ].filter { !$0.isEmpty }.joined(separator: "\r\n")
    }

    private func icsTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }
}

enum CalendarError: LocalizedError, Equatable {
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Necesitamos permiso para agregar eventos a tu calendario."
        case .saveFailed:       return "No se pudo agregar al calendario."
        }
    }
}
