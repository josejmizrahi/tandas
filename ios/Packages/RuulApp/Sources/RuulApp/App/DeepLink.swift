import Foundation

/// Single typed representation of every external entry-point URL Ruul
/// accepts. Parsed once at the boundary (`RuulAppShell.onOpenURL`) and
/// then handed off to `DeepLinkRouter`, which decides what the shell
/// should do with it.
///
/// Supported shapes:
///
///     ruul://group/<group-uuid>
///     ruul://group/<group-uuid>/decision/<decision-uuid>
///     ruul://group/<group-uuid>/sanction/<sanction-uuid>     [V3-A4]
///     ruul://group/<group-uuid>/dispute/<dispute-uuid>       [V3-A4]
///     ruul://group/<group-uuid>/member/<membership-uuid>     [V3-A4]
///     ruul://group/<group-uuid>/mandate/<mandate-uuid>       [V3-A4]
///     ruul://group/<group-uuid>/money                        [V3-A4]
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

    /// Group context for every supported link — the shell uses this to
    /// switch focus before applying the entity-specific destination.
    public var groupId: UUID {
        switch self {
        case .group(let id):                return id
        case .decision(let groupId, _),
             .sanction(let groupId, _),
             .dispute(let groupId, _),
             .member(let groupId, _),
             .mandate(let groupId, _):      return groupId
        case .money(let groupId):           return groupId
        }
    }

    /// `ruul://group/<UUID>[/<entity>/<UUID>]` parser.
    /// For custom schemes `URL.host` carries the first path segment
    /// (e.g. `group`), so we collapse host + path into a flat segment
    /// list and match positionally.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "ruul" else { return nil }

        var segments: [String] = []
        if let host = url.host, !host.isEmpty {
            segments.append(host)
        }
        segments.append(contentsOf: url.pathComponents.filter { $0 != "/" })

        guard segments.first?.lowercased() == "group", segments.count >= 2 else {
            return nil
        }
        guard let groupId = UUID(uuidString: segments[1]) else { return nil }

        if segments.count == 2 {
            return .group(groupId: groupId)
        }

        // `ruul://group/<gid>/money` — no trailing entity id.
        if segments.count == 3, segments[2].lowercased() == "money" {
            return .money(groupId: groupId)
        }

        // `ruul://group/<gid>/<entity>/<eid>` — two-segment entity tail.
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
