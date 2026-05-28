import Foundation
import Observation

/// `@MainActor` coordinator that buffers the most recent deep link the
/// system handed us. `RuulAppShell` observes `pending` and routes
/// accordingly — switching the focused group, then presenting the
/// matching detail surface for entity-scoped links.
///
/// The router is a pure state holder. Keeping navigation in the shell
/// avoids tangling this with SwiftUI's `NavigationPath` lifecycle and
/// keeps the router trivially testable.
@MainActor
@Observable
public final class DeepLinkRouter {
    public private(set) var pending: DeepLink?

    public init() {}

    /// Parses + buffers the URL. Returns `true` when the URL matched a
    /// known shape and was accepted, `false` otherwise.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let link = DeepLink.parse(url) else { return false }
        pending = link
        return true
    }

    /// V2-G7 — in-app navigation. Lets feature surfaces (history rows,
    /// search results) push a destination through the same shell
    /// plumbing the external URL path uses, without round-tripping
    /// through a synthetic URL.
    public func apply(_ link: DeepLink) {
        pending = link
    }

    /// Called by the shell once a pending link has been fully applied,
    /// so the same link doesn't reapply on subsequent renders.
    public func consume() {
        pending = nil
    }
}
