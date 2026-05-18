import Foundation

/// Deep-link plumbing: handles incoming URLs (custom scheme + universal
/// link) and APNs notification taps, decodes them into the typed
/// `pending*` slots on AppState, and exposes `consume*` methods for
/// surfaces that have routed.
///
/// Extracted from `AppState.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §2.1
/// (god-object split). All stored state these methods mutate
/// (pendingInviteCode, pendingClaimToken, pending*DeepLink,
/// pendingVoteId, pendingFineId, pendingPlaceholderClaims) lives on
/// the class declaration since class extensions can't add stored state.
public extension AppState {

    func handleIncomingURL(_ url: URL) {
        // Placeholder claim magic link (ruul://claim/<token> or
        // https://ruul.app/claim/<token>). Token is opaque hex from
        // mig 00315 — captured into `pendingClaimToken`; the root shell
        // shows ClaimReviewView when this is set.
        if let token = Self.parseClaimToken(from: url) {
            pendingClaimToken = token
            return
        }
        // Invite codes take precedence over deeplinks below
        if let code = InviteLinkGenerator.parseInviteCode(from: url) {
            pendingInviteCode = code
            return
        }
        // Unified deeplink catalog (Level 15)
        if let link = NotificationDeepLink(url: url) {
            applyDeepLink(link)
            return
        }
        // Legacy fallbacks for back-compat
        if let ruleLink = RuleChangeDeepLink(url: url) {
            pendingRuleChangeDeepLink = ruleLink
        } else if let link = EventDeepLink(url: url) {
            pendingEventDeepLink = link
        } else if let link = ResourceDeepLink(url: url) {
            // Polymorphic resource link (fund/asset/slot/space/right) —
            // los 5 tipos non-event que antes no tenían handler. El
            // detail polimórfico (ResourceDetailSheet) hidrata el
            // chrome correcto. Reusamos pendingEventDeepLink ya que
            // ambos terminan en el mismo router.openResource(id:).
            pendingEventDeepLink = EventDeepLink(eventId: link.resourceId)
        }
    }

    func handleIncomingNotification(userInfo: [AnyHashable: Any]) {
        let kind = (userInfo["deep_link_kind"] as? String)
            ?? (userInfo["kind"] as? String)
            ?? "unknown"
        let beta = BetaAnalytics(analytics: analytics)
        Task { await beta.notificationTapped(kind: kind) }

        // Unified deeplink catalog (Level 15)
        if let link = NotificationDeepLink(userInfo: userInfo) {
            applyDeepLink(link)
            return
        }
        // Legacy fallback
        if let link = EventDeepLink(userInfo: userInfo) {
            pendingEventDeepLink = link
        } else if let link = ResourceDeepLink(userInfo: userInfo) {
            pendingEventDeepLink = EventDeepLink(eventId: link.resourceId)
        }
    }

    private func applyDeepLink(_ link: NotificationDeepLink) {
        switch link {
        case .event(let id):
            pendingEventDeepLink = EventDeepLink(eventId: id)
        case .vote(let id):
            pendingVoteId = id
        case .fine(let id):
            pendingFineId = id
        case .ruleChange(let ruleId, let amount):
            // Reconstruct the canonical URL so RuleChangeDeepLink.init?(url:) can parse it.
            let proposedAmount = amount ?? 0
            if let url = URL(string: "ruul://rule/\(ruleId.uuidString)/edit?proposedAmount=\(proposedAmount)"),
               let ruleLink = RuleChangeDeepLink(url: url) {
                pendingRuleChangeDeepLink = ruleLink
            }
        }
    }

    func consumePendingInvite() {
        pendingInviteCode = nil
    }

    func consumePendingClaimToken() {
        pendingClaimToken = nil
    }

    /// Re-fetches `pendingPlaceholderClaims` from `claimRepo`. Called by
    /// `start()` once a session is live and after a claim accept/decline so
    /// PendingClaimsView reflects the latest server state. Silent on error
    /// — leaves the previous list intact rather than blocking the UI.
    func refreshPendingPlaceholderClaims() async {
        guard let repo = claimRepo else {
            self.pendingPlaceholderClaims = []
            return
        }
        do {
            self.pendingPlaceholderClaims = try await repo.discoverPending()
        } catch {
            // Network/RLS errors are non-fatal; keep last-good list.
        }
    }

    /// Parses a placeholder-claim token from either the custom scheme
    /// (`ruul://claim/<token>`) or the universal link
    /// (`https://{ruul.mx,ruul.app}/claim/<token>`). Returns nil for any
    /// other URL shape so the caller can fall through to other handlers.
    static func parseClaimToken(from url: URL) -> String? {
        // Custom scheme: ruul://claim/<token>
        if url.scheme == "ruul", url.host == "claim" {
            let token = url.lastPathComponent
            return token.isEmpty ? nil : token
        }
        // Universal link via RuulDomain (canonical ruul.mx + legacy ruul.app).
        if RuulDomain.isOurHTTPS(url),
           url.pathComponents.count >= 3, url.pathComponents[1] == "claim" {
            let token = url.pathComponents[2]
            return token.isEmpty ? nil : token
        }
        return nil
    }

    func consumeEventDeepLink() {
        pendingEventDeepLink = nil
    }

    func consumeRuleChangeDeepLink() {
        pendingRuleChangeDeepLink = nil
    }

    func consumeVoteDeepLink() {
        pendingVoteId = nil
    }

    func consumeFineDeepLink() {
        pendingFineId = nil
    }
}
