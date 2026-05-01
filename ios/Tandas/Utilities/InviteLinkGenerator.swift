import Foundation

/// Builds shareable invite URLs. V1 uses a custom scheme `ruul://invite/<code>`
/// to avoid the AASA dependency. The code is identical to the existing
/// `groups.invite_code` (8-char hex string).
///
/// Invariant: the URL format must remain identical when V2 swaps to
/// `https://ruul.app/invite/<code>` so old shared messages keep working.
/// AppEnvironment URL handler accepts BOTH forms.
enum InviteLinkGenerator {
    /// Custom scheme URL — only opens the app if installed. Used for paste
    /// 5 founder share message in V1.
    static func customScheme(code: String) -> URL {
        URL(string: "ruul://invite/\(code)")!
    }

    /// HTTPS URL — used in shareable messages for V2 once AASA is live.
    /// In V1 we still send this in the message body (because users may not
    /// have ruul installed) but pair it with the App Store fallback.
    static func universal(code: String) -> URL {
        URL(string: "https://ruul.app/invite/\(code)")!
    }

    /// Pre-formatted share message used by `ShareLink` in `InviteMembersView`.
    static func shareMessage(groupName: String, code: String) -> String {
        "Te invito a \(groupName) en ruul. Aquí coordinamos todo: turnos, RSVP, " +
        "reglas. Únete: \(universal(code: code).absoluteString)"
    }

    /// Parse an inbound URL into an invite code, if it matches either format.
    static func parseInviteCode(from url: URL) -> String? {
        // ruul://invite/<code>
        if url.scheme == "ruul", url.host == "invite" {
            return url.pathComponents.dropFirst().first
        }
        // https://ruul.app/invite/<code>
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "ruul.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "invite" {
            return url.pathComponents[2]
        }
        return nil
    }
}
