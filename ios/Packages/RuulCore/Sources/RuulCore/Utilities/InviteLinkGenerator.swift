import Foundation

/// Builds shareable invite URLs. V1 uses a custom scheme `ruul://invite/<code>`
/// to avoid the AASA dependency. The code is identical to the existing
/// `groups.invite_code` (8-char hex string).
///
/// Canonical web host comes from `RuulDomain` (mig to ruul.mx 2026-05-18).
/// Old shared messages on `ruul.app` keep parsing because RuulDomain
/// still whitelists that host.
public enum InviteLinkGenerator {
    /// Custom scheme URL — only opens the app if installed. Used for paste
    /// 5 founder share message in V1.
    public static func customScheme(code: String) -> URL {
        URL(string: "ruul://invite/\(code)")!
    }

    /// HTTPS URL — used in shareable messages once AASA is live. Emits
    /// the canonical host (`ruul.mx`). Older messages with `ruul.app`
    /// still parse via the accepted-hosts list.
    public static func universal(code: String) -> URL {
        URL(string: "https://\(RuulDomain.canonical)/invite/\(code)")!
    }

    /// Pre-formatted share message used by `ShareLink` in `InviteMembersView`
    /// and `GroupInfoSheet`.
    ///
    /// Beta 1 W1-5: shipped the universal `https://ruul.app/invite/<code>`
    /// URL alongside the message — AASA isn't live, so the link opened
    /// Safari to a 404 and the invitee abandoned. New format leads with
    /// the plaintext 6-char code (uppercased for easy copy) and gives the
    /// recipient a one-line action: download Ruul, tap "Unirme con código",
    /// paste. No dead URLs.
    public static func shareMessage(groupName: String, code: String) -> String {
        """
        Te invito a "\(groupName)" en Ruul.

        Código: \(code.uppercased())

        Descarga la app y entra con ese código en "Unirme con código".
        """
    }

    /// Parse an inbound URL into an invite code, if it matches either format.
    public static func parseInviteCode(from url: URL) -> String? {
        // ruul://invite/<code>
        if url.scheme == "ruul", url.host == "invite" {
            return url.pathComponents.dropFirst().first
        }
        // https://{ruul.mx,ruul.app}/invite/<code>
        if RuulDomain.isOurHTTPS(url),
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "invite" {
            return url.pathComponents[2]
        }
        return nil
    }
}
