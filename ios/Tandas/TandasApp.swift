import SwiftUI
import OSLog
import Sentry
import RuulApp

@main
struct TandasApp: App {
    init() {
        Self.startSentry()
    }

    var body: some Scene {
        WindowGroup {
            RuulAppShell()
                .tint(.accentColor)
        }
    }

    /// Sentry MVP — solo crash capture. PII (email, username, IP) se limpia
    /// en beforeSend para que los eventos queden anonimizados.
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
        log.info("Sentry active — release=ruul-ios@\(shortVersion)+\(buildNumber)")
    }
}
