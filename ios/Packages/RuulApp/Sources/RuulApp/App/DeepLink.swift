import Foundation

/// Single typed representation of every external entry-point URL Ruul
/// accepts. Parsed once at the boundary (`RuulAppShell.onOpenURL` /
/// `onContinueUserActivity`) and then handed off to `DeepLinkRouter`.
///
/// Supported shapes — same set is accepted under both schemes:
///
///     CUSTOM SCHEME (in-app share / pasted URI):
///       ruul://group/<group-uuid>
///       ruul://group/<group-uuid>/decision/<decision-uuid>
///       ruul://group/<group-uuid>/sanction/<sanction-uuid>     [V3-A4]
///       ruul://group/<group-uuid>/dispute/<dispute-uuid>       [V3-A4]
///       ruul://group/<group-uuid>/member/<membership-uuid>     [V3-A4]
///       ruul://group/<group-uuid>/mandate/<mandate-uuid>       [V3-A4]
///       ruul://group/<group-uuid>/money                        [V3-A4]
///       ruul://invite/<CODE>                                   [V3-DOMAIN]
///
///     UNIVERSAL LINKS (tap from WhatsApp / Messages / Mail / web):
///       https://ruul.mx/group/<group-uuid>...                  [V3-DOMAIN]
///       https://ruul.mx/invite/<CODE>                          [V3-DOMAIN]
///
/// Unknown paths return `nil` so the shell can silently ignore them
/// instead of erroring out.
public enum DeepLink: Equatable, Sendable, Hashable {
    case group(groupId: UUID)
    case decision(groupId: UUID, decisionId: UUID)
    case sanction(groupId: UUID, sanctionId: UUID)
    case dispute(groupId: UUID, disputeId: UUID)
    case member(groupId: UUID, membershipId: UUID)
    case mandate(groupId: UUID, mandateId: UUID)
    case money(groupId: UUID)
    /// V3-DOMAIN — `https://ruul.mx/invite/<CODE>` or `ruul://invite/<CODE>`.
    /// Code is the 8-char redemption token issued by `invite_member`.
    case invite(code: String)

    /// Group context for every group-scoped link — the shell uses this
    /// to switch focus before applying the entity-specific destination.
    /// Nil for cross-group links (e.g. `.invite`).
    public var groupId: UUID? {
        switch self {
        case .group(let id):                return id
        case .decision(let groupId, _),
             .sanction(let groupId, _),
             .dispute(let groupId, _),
             .member(let groupId, _),
             .mandate(let groupId, _):      return groupId
        case .money(let groupId):           return groupId
        case .invite:                       return nil
        }
    }

    /// Accepts both `ruul://...` (custom scheme) and `https://ruul.mx/...`
    /// (universal link) URLs. For custom schemes `URL.host` carries the
    /// first path segment (e.g. `group`); for HTTPS the host is the
    /// domain. We normalise to a flat segment list and match positionally.
    public static func parse(_ url: URL) -> DeepLink? {
        let scheme = url.scheme?.lowercased() ?? ""
        let isCustomScheme = scheme == "ruul"
        let isUniversalLink = (scheme == "https" || scheme == "http")
            && (url.host?.lowercased() == "ruul.mx" || url.host?.lowercased() == "www.ruul.mx")
        guard isCustomScheme || isUniversalLink else { return nil }

        // Flatten host + path into segments. For ruul://group/X the host
        // is "group" and pathComponents = ["/", "X"]; for https://ruul.mx
        // the host is "ruul.mx" (dropped) and pathComponents carry the
        // route prefix.
        var segments: [String] = []
        if isCustomScheme, let host = url.host, !host.isEmpty {
            segments.append(host)
        }
        segments.append(contentsOf: url.pathComponents.filter { $0 != "/" && !$0.isEmpty })

        guard let head = segments.first?.lowercased() else { return nil }

        switch head {
        case "invite":
            // /invite/<CODE>
            guard segments.count >= 2 else { return nil }
            let code = segments[1].uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return nil }
            return .invite(code: code)
        case "group":
            return parseGroupScoped(segments)
        default:
            return nil
        }
    }

    private static func parseGroupScoped(_ segments: [String]) -> DeepLink? {
        guard segments.count >= 2, let groupId = UUID(uuidString: segments[1]) else {
            return nil
        }
        if segments.count == 2 {
            return .group(groupId: groupId)
        }
        if segments.count == 3, segments[2].lowercased() == "money" {
            return .money(groupId: groupId)
        }
        guard segments.count == 4,
              let entityId = UUID(uuidString: segments[3])
        else { return nil }
        switch segments[2].lowercased() {
        case "decision": return .decision(groupId: groupId, decisionId: entityId)
        case "sanction": return .sanction(groupId: groupId, sanctionId: entityId)
        case "dispute":  return .dispute(groupId: groupId, disputeId: entityId)
        case "member":   return .member(groupId: groupId, membershipId: entityId)
        case "mandate":  return .mandate(groupId: groupId, mandateId: entityId)
        default:         return nil
        }
    }
}
