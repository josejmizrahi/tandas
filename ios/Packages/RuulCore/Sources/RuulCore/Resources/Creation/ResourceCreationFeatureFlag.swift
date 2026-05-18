import Foundation

/// Persisted feature flag for the new resource creation flow rollout.
///
/// Per doctrine 2026-05-18 cutover plan:
///   - OFF (default) → caller presents the legacy `ResourceWizardSheet`
///     (5-step Type → Fields → Options → Rules → Review with capability
///     toggles).
///   - ON → caller presents the new `ResourceCreationSheet` (3-step
///     Type → Variant → Identity → Create → Intents, capabilities
///     invisible).
///
/// Flag stored in `UserDefaults` so it survives app launches and can
/// be flipped from a debug menu without rebuilding. Production cutover
/// is a single line change in the default value here once the new flow
/// is validated end-to-end on the 5 founder cases.
public enum ResourceCreationFeatureFlag {
    private static let key = "ruul.feature.creationFlowV2.enabled"

    /// Default ON for development builds (DEBUG), OFF for release until
    /// the founder smoke test passes. Lets internal builds flip the
    /// switch instantly via UserDefaults while shipping a conservative
    /// default to prod.
    private static var fallback: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// True when callers should present the new `ResourceCreationSheet`.
    /// False (default) means present the legacy `ResourceWizardSheet`.
    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil {
                return fallback
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    /// Reset to the default (removes the override). Used by debug
    /// "Reset to default" buttons + tests that want a clean slate.
    public static func clearOverride() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
