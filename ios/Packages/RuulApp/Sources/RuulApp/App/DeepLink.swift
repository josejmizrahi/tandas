import Foundation

/// Single typed representation of every external entry-point URL Ruul
/// accepts. Parsed once at the boundary (`RuulAppShell.onOpenURL`) and
/// then handed off to `DeepLinkRouter`, which decides what the shell
/// should do with it.
///
/// Supported shapes (D4):
///
///     ruul://group/<group-uuid>
///     ruul://group/<group-uuid>/decision/<decision-uuid>
///
/// Unknown paths return `nil` so the shell can silently ignore them
/// instead of erroring out — the V1 surface is intentionally narrow
/// and we'd rather drop malformed URLs than crash on them.
public enum DeepLink: Equatable, Sendable, Hashable {
    case group(groupId: UUID)
    case decision(groupId: UUID, decisionId: UUID)

    /// Group context for every supported link — the shell uses this to
    /// switch focus before applying the entity-specific destination.
    public var groupId: UUID {
        switch self {
        case .group(let id):              return id
        case .decision(let groupId, _):   return groupId
        }
    }

    /// `ruul://group/<UUID>[/decision/<UUID>]` parser.
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
        if segments.count == 4,
           segments[2].lowercased() == "decision",
           let decisionId = UUID(uuidString: segments[3]) {
            return .decision(groupId: groupId, decisionId: decisionId)
        }
        return nil
    }
}
