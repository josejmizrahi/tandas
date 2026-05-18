import Foundation

/// Deep link payload extracted from a tapped notification or URL.
/// Used to route the user from the notification → EventDetailView.
public struct EventDeepLink: Sendable, Hashable {
    public let eventId: UUID

    public static let userInfoKey = "ruul_event_id"

    public init(eventId: UUID) {
        self.eventId = eventId
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String,
              let id = UUID(uuidString: raw)
        else { return nil }
        self.eventId = id
    }

    public init?(url: URL) {
        // Accepts both ruul://event/<id> and https://{ruul.mx,ruul.app}/event/<id>.
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "ruul", url.host == "event",
           let last = url.pathComponents.last(where: { $0 != "/" }),
           let id = UUID(uuidString: last) {
            self.eventId = id
            return
        }
        if RuulDomain.isOurHTTPS(url),
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "event",
           let id = UUID(uuidString: url.pathComponents[2]) {
            self.eventId = id
            return
        }
        return nil
    }

    public var userInfo: [AnyHashable: Any] {
        [Self.userInfoKey: eventId.uuidString]
    }
}
