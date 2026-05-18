import Foundation

/// Errors a `PostCreateIntentDispatcher` may surface to the screen.
/// Designed to round-trip through the screen's inline error banner —
/// the localized description is what the user sees.
public enum IntentDispatchError: LocalizedError, Sendable {
    /// One or more required capabilities failed to attach. The screen
    /// shows the inline error and lets the user pick a different intent.
    /// Map of `capabilityId → underlying error message`.
    case activationFailed([String: String])

    /// The capability ids the intent requires aren't available on the
    /// group (active modules don't provide them) AND weren't already
    /// attached on the resource. Shouldn't normally fire because the
    /// visibility resolver hides these intents, but kept as a defense
    /// against race conditions (module turned off mid-tap).
    case capabilitiesUnavailable(Set<String>)

    /// The destination case has no presentation wired yet. Phase B.1
    /// renders a placeholder so the menu entry doesn't dead-end.
    case destinationNotImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .activationFailed(let map):
            let ids = map.keys.sorted().joined(separator: ", ")
            return "No pudimos activar: \(ids). Inténtalo de nuevo."
        case .capabilitiesUnavailable(let ids):
            let list = ids.sorted().joined(separator: ", ")
            return "Falta habilitar el módulo para: \(list)."
        case .destinationNotImplemented(let label):
            return "\(label) llega en la siguiente iteración."
        }
    }
}
