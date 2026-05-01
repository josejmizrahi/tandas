import Foundation

/// Deep link payload extracted from a tapped notification or URL.
/// Used to route the user from the notification → EventDetailView.
struct EventDeepLink: Sendable, Hashable {
    let eventId: UUID

    static let userInfoKey = "ruul_event_id"

    init(eventId: UUID) {
        self.eventId = eventId
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String,
              let id = UUID(uuidString: raw)
        else { return nil }
        self.eventId = id
    }

    init?(url: URL) {
        // Accepts both ruul://event/<id> and https://ruul.app/event/<id>.
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "ruul", url.host == "event",
           let last = url.pathComponents.last(where: { $0 != "/" }),
           let id = UUID(uuidString: last) {
            self.eventId = id
            return
        }
        if (scheme == "https" || scheme == "http"),
           url.host == "ruul.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "event",
           let id = UUID(uuidString: url.pathComponents[2]) {
            self.eventId = id
            return
        }
        return nil
    }

    var userInfo: [AnyHashable: Any] {
        [Self.userInfoKey: eventId.uuidString]
    }
}
