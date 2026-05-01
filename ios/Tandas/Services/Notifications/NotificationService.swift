import Foundation
import UserNotifications
import UIKit
import OSLog

/// Manages local + remote notifications.
///
/// V1 scope:
/// - Local notifications fully wired (24h/2h/start reminders for "going" RSVPs).
/// - Remote notification token registration ready, but the corresponding
///   server-side dispatch (send-event-notification edge function) is stubbed
///   until APNs cert is configured. See Plans/EventLayerV1.md §1.2.
@MainActor @Observable
final class NotificationService: NSObject {
    enum AuthorizationStatus: Sendable, Hashable {
        case notDetermined, denied, granted, provisional
    }

    private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    private(set) var lastDeviceToken: String?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "notifications")
    private let tokenRepo: any NotificationTokenRepository

    init(tokenRepo: any NotificationTokenRepository) {
        self.tokenRepo = tokenRepo
        super.init()
        center.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = mapStatus(settings.authorizationStatus)
    }

    /// Lazy permission: called on first "Voy" RSVP per the spec.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            if granted {
                registerForRemoteNotifications()
            }
            return granted
        } catch {
            log.warning("requestAuthorization threw: \(error.localizedDescription)")
            return false
        }
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegisterDeviceToken(_ token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        lastDeviceToken = hex
        do {
            try await tokenRepo.registerToken(hex)
            log.debug("registered APNs token")
        } catch {
            log.error("registerToken failed: \(error.localizedDescription)")
        }
    }

    /// Schedule the 3 reminders for an event. Idempotent: re-scheduling
    /// replaces previous notifications for the same eventId.
    func scheduleLocalReminders(for event: Event, vocabulary: String) async {
        await cancelLocalReminders(for: event.id)
        guard authorizationStatus == .granted else { return }

        let reminders: [(slot: String, fire: Date, title: String, body: String)] = [
            (
                "24h",
                event.startsAt.addingTimeInterval(-24 * 3600),
                "Mañana es \(vocabulary)",
                event.title
            ),
            (
                "2h",
                event.startsAt.addingTimeInterval(-2 * 3600),
                "\(vocabulary.capitalized) en 2h",
                "¿Confirmas? \(event.title)"
            ),
            (
                "start",
                event.startsAt,
                "Empezó \(vocabulary)",
                "Marca tu llegada — \(event.title)"
            )
        ]

        for r in reminders where r.fire > .now {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = EventDeepLink(eventId: event.id).userInfo

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier(for: event.id, slot: r.slot),
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                log.warning("add notification failed for \(r.slot): \(error.localizedDescription)")
            }
        }
    }

    func cancelLocalReminders(for eventId: UUID) async {
        let identifiers = ["24h", "2h", "start"].map { identifier(for: eventId, slot: $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func handleDeepLink(from notification: UNNotification) -> EventDeepLink? {
        EventDeepLink(userInfo: notification.request.content.userInfo)
    }

    private func identifier(for eventId: UUID, slot: String) -> String {
        "event-\(eventId.uuidString)-\(slot)"
    }

    private func mapStatus(_ status: UNAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        case .provisional:   return .provisional
        case .ephemeral:     return .granted
        @unknown default:    return .notDetermined
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
