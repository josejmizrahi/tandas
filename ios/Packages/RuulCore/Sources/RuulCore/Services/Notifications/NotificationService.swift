import Foundation
import UserNotifications
import UIKit
import OSLog

/// Manages local + remote notifications.
///
/// V1 scope:
/// - Local notifications fully wired (24h/2h/start reminders for "going" RSVPs).
/// - Remote notification token registration ready. Server-side flow is
///   outbox-first: edge functions write to `notifications_outbox`; a
///   `dispatch-notifications` cron (pending) reads pending rows and
///   sends APNs once creds are configured. See Plans/Audit-2026-05-06.md
///   §9 (APNs sprint).
@MainActor @Observable
public final class NotificationService: NSObject {
    public enum AuthorizationStatus: Sendable, Hashable {
        case notDetermined, denied, granted, provisional
    }

    public private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    public private(set) var lastDeviceToken: String?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "notifications")
    private let tokenRepo: any NotificationTokenRepository

    public init(tokenRepo: any NotificationTokenRepository) {
        self.tokenRepo = tokenRepo
        super.init()
        center.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    public func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = mapStatus(settings.authorizationStatus)
        // iOS conserva el grant entre instalaciones del mismo bundle id.
        // Si ya está granted, requestAuthorization() no se vuelve a llamar
        // y registerForRemoteNotifications() tampoco — pero la build nueva
        // necesita un fresh APNs token. Re-registrar cada launch lo
        // resuelve. registerForRemoteNotifications es idempotente (Apple
        // docs) — llamarla múltiples veces sólo dispara
        // didRegisterForRemoteNotificationsWithDeviceToken otra vez.
        if authorizationStatus == .granted {
            registerForRemoteNotifications()
        }
    }

    /// Lazy permission: called on first "Voy" RSVP per the spec.
    public func requestAuthorization() async -> Bool {
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

    public func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    public func didRegisterDeviceToken(_ token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        lastDeviceToken = hex
        do {
            try await tokenRepo.registerToken(hex)
            log.debug("registered APNs token")
        } catch {
            log.error("registerToken failed: \(error.localizedDescription)")
        }
    }

    /// Revoke the locally-registered APNs token from the server (best-effort)
    /// and clear local state.
    ///
    /// Called by `AppState.signOut()` before `auth.signOut()` so that the
    /// device's `notification_tokens` row is detached from the user before
    /// they leave. Without this step, a shared family device that switches
    /// users keeps delivering APNs pushes addressed to the original user
    /// to whoever now holds the phone — a cross-user data leak.
    ///
    /// Semantics:
    /// - If no token was registered this session, no-op.
    /// - Repo errors (network drop, server transient failure) are logged
    ///   and swallowed: the user must always end up signed out client-side
    ///   even if the server-side revoke fails. The orphaned row is
    ///   recoverable via the server-side outbox janitor + future
    ///   `notification_tokens` cleanup on member removal.
    /// - Also clears the app icon badge and pending/delivered local
    ///   notifications so the next user lands on a fresh notification state.
    public func revokeTokenIfRegistered() async {
        if let token = lastDeviceToken {
            do {
                try await tokenRepo.revokeToken(token)
                log.debug("revoked APNs token on sign out")
            } catch {
                log.warning("revokeToken on sign out failed: \(error.localizedDescription)")
            }
        }
        lastDeviceToken = nil
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
    }

    /// Schedule the 3 reminders for an event. Idempotent: re-scheduling
    /// replaces previous notifications for the same eventId.
    public func scheduleLocalReminders(for event: Event, vocabulary: String) async {
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

    public func cancelLocalReminders(for eventId: UUID) async {
        let identifiers = ["24h", "2h", "start"].map { identifier(for: eventId, slot: $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func handleDeepLink(from notification: UNNotification) -> EventDeepLink? {
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
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
