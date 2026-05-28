import SwiftUI
import OSLog
import Sentry
import RuulApp

@main
struct TandasApp: App {
    /// V3-A2 — owns the APNs lifecycle (token register + tap →
    /// DeepLinkRouter forwarding). SwiftUI guarantees a single
    /// instance per process; `RuulAppShell` binds the container into
    /// it after construction.
    @UIApplicationDelegateAdaptor(RuulAppDelegate.self) private var appDelegate

    init() {
        Self.startSentry()
    }

    var body: some Scene {
        WindowGroup {
            RuulAppShell()
                .tint(.accentColor)
        }
    }

    /// Sentry MVP — crash capture only. No performance monitoring, no
    /// breadcrumbs beyond the SDK defaults. PII (email, username, IP) is
    /// scrubbed in beforeSend so events stay anonymized.
    private static func startSentry() {
        let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "sentry")
        let dsn = (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String) ?? ""
        guard !dsn.isEmpty else {
            log.info("Sentry inactive — no DSN configured in Info.plist")
            return
        }
        let shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "ruul-ios@\(shortVersion)+\(buildNumber)"
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.tracesSampleRate = 0.0
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.beforeSend = { event in
                event.user?.email = nil
                event.user?.username = nil
                event.user?.ipAddress = nil
                return event
            }
        }
        let dsnTail = dsn.suffix(8)
        log.info("Sentry active — release=ruul-ios@\(shortVersion)+\(buildNumber) dsn=…\(dsnTail)")
    }
}
