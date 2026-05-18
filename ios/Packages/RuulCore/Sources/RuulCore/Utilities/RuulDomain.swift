import Foundation

/// Central canon for the Ruul web domain — single source of truth for
/// canonical (outbound) URL emission and parser host whitelisting.
///
/// History: V1 shipped on `ruul.app`. 2026-05-18 the founder bought
/// `ruul.mx` and migrated marketing + Universal Links there. All NEW
/// URLs are emitted on `ruul.mx`. Parsers accept BOTH so older WhatsApp
/// bodies that already shipped with `ruul.app` keep opening the app.
///
/// Add new hosts here (e.g. preview deploys like `staging.ruul.mx`) and
/// every parser picks them up automatically.
public enum RuulDomain {
    /// Host used when GENERATING new URLs. Single value, no negotiation —
    /// keep callers consistent across edge fns, WhatsApp bodies, and iOS
    /// share sheets.
    public static let canonical: String = "ruul.mx"

    /// Hosts a parser will treat as "this is one of ours". Includes the
    /// canonical host + legacy + the `www.` variant of each. Keep the
    /// list small; every entry is a path Apple's AASA must cover.
    public static let acceptedHosts: Set<String> = [
        "ruul.mx",
        "www.ruul.mx",
        "ruul.app",
        "www.ruul.app",
    ]

    /// True when the URL is HTTPS (or HTTP for back-compat) and the host
    /// is one we own. Used by every parser as the first gate before
    /// inspecting the path.
    public static func isOurHTTPS(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return acceptedHosts.contains(host)
    }
}
