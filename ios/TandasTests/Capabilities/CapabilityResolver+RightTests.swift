import Testing
import Foundation
import RuulCore
@testable import Tandas

/// Coverage for the right-specific branches of `CapabilityResolver.secondaryActions`
/// + `.primaryAction`, plus the affirmative-only visibility rules they enforce.
/// Shipped after slices 6 / 14 ran without any test backstop — this is the
/// regression guard.
@Suite("CapabilityResolver — right")
struct CapabilityResolverRightTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    // MARK: - Helpers

    /// IDs used by the test rows so we can talk about "viewer is the holder"
    /// without resorting to comparing freshly-minted UUIDs.
    private let holderUserId = UUID()
    private let delegateUserId = UUID()
    private let strangerUserId = UUID()

    /// Builds a right ResourceRow with a metadata jsonb shaped like what
    /// `create_right` writes — same key names so the resolver's reads
    /// behave identically to prod.
    private func makeRight(
        status: String = "active",
        holderUserId: UUID,
        delegateUserId: UUID? = nil,
        transferable: Bool = false,
        delegable: Bool = false,
        suspended: Bool = false
    ) -> ResourceRow {
        var meta: [String: JSONConfig] = [
            "name":           .string("Test right"),
            "holder_user_id": .string(holderUserId.uuidString),
            "transferable":   .bool(transferable),
            "delegable":      .bool(delegable),
        ]
        if let delegateUserId {
            meta["delegate_user_id"] = .string(delegateUserId.uuidString)
        }
        if suspended {
            meta["suspended_at"] = .string("2026-05-15T10:00:00Z")
        }
        return ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .right,
            status: status,
            metadata: .object(meta),
            createdBy: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    // MARK: - secondaryActions tests

    @Test("stranger viewer → only Compartir (no holder/admin actions)")
    func strangerSeesOnlyShare() {
        let right = makeRight(holderUserId: holderUserId, transferable: true, delegable: true)
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: strangerUserId
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds == [.share])
        #expect(!kinds.contains(.exerciseRight))
        #expect(!kinds.contains(.transferRight))
        #expect(!kinds.contains(.delegateRight))
        #expect(!kinds.contains(.revokeRight))
        #expect(!kinds.contains(.suspendRight))
        #expect(!kinds.contains(.editDetails))
    }

    @Test("holder viewer + active + not suspended + transferable → Ejercer + Transferir")
    func holderActiveTransferable() {
        let right = makeRight(
            holderUserId: holderUserId,
            transferable: true,
            delegable: false
        )
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.exerciseRight))
        #expect(kinds.contains(.transferRight))
        #expect(!kinds.contains(.delegateRight),
                "delegate button stays hidden when delegable=false")
        #expect(!kinds.contains(.revokeRight),
                "revoke is admin-only — member holder doesn't see it")
        #expect(!kinds.contains(.editDetails),
                "edit is admin-only")
    }

    @Test("non-transferable right → no Transferir even for holder")
    func nonTransferableHidesTransfer() {
        let right = makeRight(
            holderUserId: holderUserId,
            transferable: false
        )
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        let kinds = Set(actions.map(\.kind))
        #expect(!kinds.contains(.transferRight))
        #expect(kinds.contains(.exerciseRight),
                "exercise still applies even when not transferable")
    }

    @Test("suspended right → no Ejercer/Transferir/Delegar/Suspender")
    func suspendedHidesActions() {
        let right = makeRight(
            holderUserId: holderUserId,
            transferable: true,
            delegable: true,
            suspended: true
        )
        let admin = resolver.secondaryActions(
            for: right,
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        let kinds = Set(admin.map(\.kind))

        #expect(!kinds.contains(.exerciseRight))
        #expect(!kinds.contains(.transferRight))
        #expect(!kinds.contains(.delegateRight))
        #expect(!kinds.contains(.suspendRight),
                "can't double-suspend; only Restore is available")
        #expect(kinds.contains(.restoreRight),
                "admin can restore a suspended right")
        #expect(kinds.contains(.revokeRight),
                "revoke still available even when suspended")
    }

    @Test("admin + active right → Suspend + Revoke + Edit; no Restore")
    func adminActiveMenu() {
        let right = makeRight(holderUserId: holderUserId)
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: strangerUserId  // admin who isn't the holder
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.suspendRight))
        #expect(kinds.contains(.revokeRight))
        #expect(kinds.contains(.editDetails))
        #expect(!kinds.contains(.restoreRight),
                "restore only when suspended or revoked")
    }

    @Test("revoked right + admin → Restore available; no Suspend/Revoke")
    func adminRevokedMenu() {
        let right = makeRight(status: "revoked", holderUserId: holderUserId)
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: strangerUserId
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.restoreRight))
        #expect(!kinds.contains(.revokeRight),
                "already revoked — Revocar would be a no-op")
        #expect(!kinds.contains(.suspendRight),
                "revoked rights aren't suspendable; need restore first")
    }

    @Test("delegate viewer → can Ejercer even though they're not the holder")
    func delegateCanExercise() {
        let right = makeRight(
            holderUserId: holderUserId,
            delegateUserId: delegateUserId,
            delegable: true
        )
        let actions = resolver.secondaryActions(
            for: right,
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: [],
            viewerUserId: delegateUserId
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.exerciseRight))
        #expect(!kinds.contains(.transferRight),
                "delegate can exercise but not reassign — that's holder's call")
        #expect(!kinds.contains(.delegateRight),
                "delegate can't sub-delegate")
    }

    // MARK: - primaryAction tests

    @Test("primary CTA: holder + active + !suspended → Ejercer")
    func primaryEjercerForHolder() {
        let right = makeRight(holderUserId: holderUserId)
        let action = resolver.primaryAction(
            for: right,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        #expect(action.kind == .exerciseRight)
        #expect(action.label == "Ejercer")
        #expect(action.style == .prominent)
    }

    @Test("primary CTA: delegate → Ejercer")
    func primaryEjercerForDelegate() {
        let right = makeRight(
            holderUserId: holderUserId,
            delegateUserId: delegateUserId,
            delegable: true
        )
        let action = resolver.primaryAction(
            for: right,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: [],
            viewerUserId: delegateUserId
        )
        #expect(action.kind == .exerciseRight)
    }

    @Test("primary CTA: stranger → none (footer hidden)")
    func primaryNoneForStranger() {
        let right = makeRight(holderUserId: holderUserId)
        let action = resolver.primaryAction(
            for: right,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: [],
            viewerUserId: strangerUserId
        )
        #expect(action.kind == .none)
    }

    @Test("primary CTA: suspended right → none even for holder")
    func primaryNoneWhenSuspended() {
        let right = makeRight(holderUserId: holderUserId, suspended: true)
        let action = resolver.primaryAction(
            for: right,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        #expect(action.kind == .none)
    }

    @Test("primary CTA: revoked right → none even for ex-holder")
    func primaryNoneWhenRevoked() {
        let right = makeRight(status: "revoked", holderUserId: holderUserId)
        let action = resolver.primaryAction(
            for: right,
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: [],
            viewerUserId: holderUserId
        )
        #expect(action.kind == .none)
    }
}
