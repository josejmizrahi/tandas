import Foundation
import Security

/// Device-level flag that distinguishes a returning logged-out user from a
/// first-time launch. Set after either onboarding flow successfully verifies
/// a real auth identity (phone OTP or Apple). When `true` and the session is
/// nil (user signed out), AuthGate routes to SignInView instead of dragging
/// the user through the entire onboarding again.
///
/// Stored in **Keychain** (not UserDefaults) so it survives app reinstalls —
/// iOS Keychain entries persist by default while UserDefaults is wiped with
/// the app container. Without this, a returning user who reinstalls the app
/// can't reach SignInView and gets dragged through founder onboarding even
/// though their account already exists.
///
/// Cleared by uninstall (iff the device opts to clear keychain on first
/// launch — opt-in, not default), or by SignInView's "Crear cuenta nueva"
/// branch.
public enum OnboardingCompletion {
    private static let service = "com.josejmizrahi.ruul.onboarding"
    private static let account = "has_onboarded"
    private static let legacyDefaultsKey = "ruul_has_onboarded"

    /// Posted whenever `mark()` / `clear()` mutates the flag, so views that
    /// can't bind directly to keychain (AuthGate) can re-read on the next
    /// runloop. Keep the name stable — multiple subscribers may listen.
    public static let didChangeNotification = Notification.Name("OnboardingCompletion.didChange")

    public static func mark() {
        guard write(true) else { return }
        // Drop the legacy UserDefaults key once we've successfully written
        // to Keychain so we don't keep two sources of truth diverging.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static func clear() {
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static var hasOnboarded: Bool {
        if read() { return true }
        // One-shot migration: devices that onboarded before the Keychain
        // move still have the flag in UserDefaults. Promote it on first
        // read so the device looks "onboarded" for AuthGate routing.
        if UserDefaults.standard.bool(forKey: legacyDefaultsKey) {
            _ = write(true)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return true
        }
        return false
    }

    // MARK: - Keychain primitives

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    private static func write(_ value: Bool) -> Bool {
        let data = (value ? "1" : "0").data(using: .utf8)!
        var query = baseQuery()
        // Best-effort upsert: try update first, fall back to add. Always
        // requests AfterFirstUnlock so background launches (push-triggered)
        // can still read the flag while keeping the item device-only.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func read() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return false
        }
        return str == "1"
    }
}
