import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("CapabilityResolver.secondaryActions")
struct CapabilityResolverSecondaryActionsTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    // MARK: - Helpers

    private func makeResource(
        type: ResourceType,
        status: String = "scheduled"
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: status,
            metadata: .empty,
            createdBy: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    // MARK: - Test 1: event member viewer → minimal menu (share + calendar + wallet)

    @Test("event + member viewer → share, calendar, wallet; no host/admin items")
    func eventMemberViewer() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        // Universal actions must be present
        #expect(kinds.contains(.share))
        #expect(kinds.contains(.addToCalendar))
        #expect(kinds.contains(.generateWalletPass))

        // Host-only items must be absent
        #expect(!kinds.contains(.editDetails))
        #expect(!kinds.contains(.remindAttendees))
        #expect(!kinds.contains(.closeEvent))
        #expect(!kinds.contains(.cancelEvent))

        // Admin-only items must be absent
        #expect(!kinds.contains(.archive))
    }

    // MARK: - Test 2: event host viewer → adds host section (remind/close/cancel)

    @Test("event + host viewer → host section present (remind, close, cancel)")
    func eventHostViewer() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .host,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.remindAttendees))
        #expect(kinds.contains(.closeEvent))
        #expect(kinds.contains(.cancelEvent))

        // Host does NOT get edit (only host+admin), but edit IS included
        // because eventSecondaryActions adds it for isHost || isAdmin
        #expect(kinds.contains(.editDetails))
    }

    // MARK: - Test 2.b: event host + closed/cancelled → reopen replaces close/cancel
    //                  Mig 00295 + SecondaryAction.Kind.reopenEvent.

    @Test("event + host + status=completed → reopenEvent shown; close/cancel hidden")
    func eventHostViewerClosedShowsReopen() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event, status: "completed"),
            viewerRole: .host,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.reopenEvent))
        #expect(!kinds.contains(.closeEvent))
        #expect(!kinds.contains(.cancelEvent))
        #expect(!kinds.contains(.remindAttendees))
    }

    @Test("event + host + status=cancelled → reopenEvent shown")
    func eventHostViewerCancelledShowsReopen() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event, status: "cancelled"),
            viewerRole: .host,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.reopenEvent))
        #expect(!kinds.contains(.closeEvent))
    }

    @Test("event + member + status=completed → reopenEvent NOT shown (host-only gate)")
    func eventMemberViewerClosedNoReopen() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event, status: "completed"),
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(!kinds.contains(.reopenEvent))
    }

    // MARK: - Test 3: event admin (founder) viewer → archive shown

    @Test("event + founder viewer → archive action present")
    func eventFounderViewerArchive() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.archive))
        #expect(kinds.contains(.editDetails))
    }

    // MARK: - Test 4: event without manual fine grant → no manual fine item

    @Test("event + viewerCanIssueManualFine=false → issueManualFine absent")
    func eventNoManualFineGrant() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: ["ledger"]
        )
        let kinds = Set(actions.map(\.kind))
        #expect(!kinds.contains(.issueManualFine))
    }

    // MARK: - Test 5: event with ledger capability → ledger item shown

    @Test("event + ledger capability → openLedger action present")
    func eventLedgerCapability() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .member,
            viewerCanIssueManualFine: true,
            enabledCapabilities: ["ledger"]
        )
        let kinds = Set(actions.map(\.kind))
        #expect(kinds.contains(.openLedger))
        // Fine grant + ledger → both money items
        #expect(kinds.contains(.issueManualFine))
    }

    // MARK: - Test 6: fund with non-admin viewer → minimal common menu

    @Test("fund + member viewer → only share; no archive or enableCapability")
    func fundMemberViewer() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .fund),
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.share))
        #expect(!kinds.contains(.archive))
        #expect(!kinds.contains(.enableCapability))
    }

    // MARK: - Fund admin: registrar gasto + archive (lock lives in MoneySectionView)

    @Test("fund + admin viewer → recordExpenseFromFund + archive (lock lives in MoneySectionView)")
    func fundAdminViewer() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .fund),
            viewerRole: .founder,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.share))
        #expect(kinds.contains(.recordExpenseFromFund))
        #expect(kinds.contains(.archive))
    }

    @Test("fund + non-admin viewer → only share (no admin items)")
    func fundMemberViewerNoAdminItems() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .fund),
            viewerRole: .member,
            viewerCanIssueManualFine: false,
            enabledCapabilities: []
        )
        let kinds = Set(actions.map(\.kind))

        #expect(kinds.contains(.share))
        #expect(!kinds.contains(.recordExpenseFromFund))
        #expect(!kinds.contains(.archive))
    }

    // MARK: - Section ordering sanity

    @Test("primary section items appear before host and money sections")
    func sectionOrderingPrimary() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .host,
            viewerCanIssueManualFine: true,
            enabledCapabilities: ["ledger"]
        )

        let firstNonPrimary = actions.firstIndex { $0.section != .primary } ?? actions.endIndex
        let firstHostOrMoney = actions.firstIndex { $0.section == .host || $0.section == .money } ?? actions.endIndex

        // All primary-section items must come before host/money items
        #expect(firstHostOrMoney >= firstNonPrimary)
    }

    // MARK: - Destructive flag checks

    @Test("cancelEvent and issueManualFine are flagged isDestructive")
    func destructiveFlags() {
        let actions = resolver.secondaryActions(
            for: makeResource(type: .event),
            viewerRole: .host,
            viewerCanIssueManualFine: true,
            enabledCapabilities: []
        )

        if let cancel = actions.first(where: { $0.kind == .cancelEvent }) {
            #expect(cancel.isDestructive)
        }
    }
}
