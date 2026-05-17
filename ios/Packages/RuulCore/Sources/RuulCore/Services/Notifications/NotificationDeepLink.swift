import Foundation

/// Unified deeplink catalog for push payloads. Server emits `deep_link`
/// with scheme `ruul://[kind]/[id]` (optional query params).
///
/// Replaces the per-type structs (EventDeepLink, RuleChangeDeepLink) for
/// new sites — existing structs can keep working for back-compat.
public enum NotificationDeepLink: Sendable, Hashable {
    case event(UUID)
    case vote(UUID)
    case fine(UUID)
    case ruleChange(ruleId: UUID, proposedAmount: Int?)

    public init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.dropFirst()  // skip "/"
        guard let firstPath = path.first, let id = UUID(uuidString: firstPath) else { return nil }
        switch host {
        case "event":
            self = .event(id)
        case "vote":
            self = .vote(id)
        case "fine":
            self = .fine(id)
        case "rule":
            // Optional query: ?proposedAmount=N
            var amount: Int?
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let val = comps.queryItems?.first(where: { $0.name == "proposedAmount" })?.value {
                amount = Int(val)
            }
            self = .ruleChange(ruleId: id, proposedAmount: amount)
        default:
            return nil
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        // Look for "deep_link" string in APNs payload.
        guard let linkStr = userInfo["deep_link"] as? String,
              let url = URL(string: linkStr) else { return nil }
        self.init(url: url)
    }

    public var id: UUID {
        switch self {
        case .event(let id), .vote(let id), .fine(let id):
            return id
        case .ruleChange(let id, _):
            return id
        }
    }
}
