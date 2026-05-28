import UIKit
import UserNotifications
import OSLog
import RuulCore

/// V3-A2 — APNs registration + push tap handler. Bridges between the
/// system push lifecycle (`UIApplicationDelegate` +
/// `UNUserNotificationCenterDelegate`) and the SwiftUI side via
/// `DependencyContainer`. The container is bound by `RuulAppShell`
/// after `init()`; any token that lands before then is buffered and
/// flushed when `bind(container:)` is called.
///
/// Tap responses extract the `deep_link` key from the APNs payload
/// (set by `supabase/functions/dispatch-notifications`) and forward
/// the URL to `DeepLinkRouter`, reusing the same plumbing that
/// `onOpenURL` uses for universal links.
@MainActor
public final class RuulAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// SwiftUI's `@UIApplicationDelegateAdaptor` constructs exactly
    /// one instance per app process. `init()` stashes it here so
    /// `RuulAppShell` can hand it the live container without needing
    /// a separate environment plumbing.
    public static weak var shared: RuulAppDelegate?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "push")
    private weak var container: DependencyContainer?
    private var pendingTokenHex: String?

    public override init() {
        super.init()
        Self.shared = self
    }

    // MARK: - Lifecycle

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Called by `RuulAppShell` once `DependencyContainer` is alive.
    /// Idempotent; flushes any token deposited before the bind.
    public func bind(container: DependencyContainer) {
        self.container = container
        if let hex = pendingTokenHex {
            pendingTokenHex = nil
            register(hex: hex)
        }
    }

    /// Called by `RuulAppShell` when the user becomes `.signedIn`. The
    /// system silently no-ops if the prompt was already answered, so
    /// this is safe to call on every signed-in transition.
    public func requestAuthorizationIfNeeded() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                log.info("Push authorization not granted")
            }
        } catch {
            log.error("Push authorization error: \(String(describing: error))")
        }
    }

    // MARK: - Token lifecycle

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if container != nil {
            register(hex: hex)
        } else {
            pendingTokenHex = hex
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        log.error("APNs registration failed: \(String(describing: error))")
    }

    private func register(hex: String) {
        guard let repo = container?.notificationsRepository else {
            pendingTokenHex = hex
            return
        }
        Task { @MainActor in
            do {
                _ = try await repo.registerToken(hex)
            } catch {
                log.error("register_my_notification_token RPC failed: \(String(describing: error))")
                pendingTokenHex = hex
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    //
    // The protocol declares these async with non-Sendable parameters
    // (UNNotification / UNNotificationResponse), so the implementation
    // must run nonisolated and hop to MainActor only after pulling
    // out the Sendable bits (the deep_link string).

    /// Foreground push — keep the banner + sound so the user sees the
    /// alert even when the app is on top.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tap response — extract the `deep_link` payload key (added by
    /// `dispatch-notifications`) and hand the URL off to
    /// `DeepLinkRouter`. Unknown / missing links are dropped silently
    /// so the tap still wakes the app.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo["deep_link"] as? String
        await MainActor.run {
            guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return }
            _ = self.container?.deepLinkRouter.handle(url)
        }
    }
}
