import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("CapabilityResolver.primaryAction")
struct CapabilityResolverPrimaryActionTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

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

    // MARK: - Event tests

    @Test("event + rsvp capability + viewer hasn't RSVP'd → rsvpConfirm")
    func eventNotRSVPdGetsConfirm() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .upcoming,
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(action.kind == .rsvpConfirm)
        #expect(!action.label.isEmpty)
        #expect(action.style == .prominent)
    }

    @Test("event + rsvp + viewer going → rsvpCancel")
    func eventRSVPdGoingGetsCancel() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event),
            viewerRole: .member,
            rsvpStatus: .going,
            eventStatus: .upcoming,
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(action.kind == .rsvpCancel)
    }

    @Test("event + viewer is host → viewHostActions")
    func eventHostGetsActions() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event),
            viewerRole: .host,
            rsvpStatus: nil,
            eventStatus: .upcoming,
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(action.kind == .viewHostActions)
    }

    @Test("event closed → viewClosed")
    func eventClosedGetsClosed() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event, status: "completed"),
            viewerRole: .member,
            rsvpStatus: .going,
            eventStatus: .closed,
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(action.kind == .viewClosed)
    }

    @Test("event cancelled → none")
    func eventCancelledHidesCTA() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event, status: "cancelled"),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .cancelled,
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(action.kind == .none)
    }

    @Test("event without rsvp capability → none")
    func eventNoRSVPCapability() {
        let action = resolver.primaryAction(
            for: makeResource(type: .event),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: .upcoming,
            enabledCapabilities: ["scheduling"]   // no rsvp
        )
        #expect(action.kind == .none)
    }

    // MARK: - Other resource type tests

    @Test("fund → openContribute placeholder")
    func fundGetsContribute() {
        let action = resolver.primaryAction(
            for: makeResource(type: .fund, status: "active"),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: []
        )
        #expect(action.kind == .openContribute)
    }

    @Test("asset → openBooking placeholder")
    func assetGetsBooking() {
        let action = resolver.primaryAction(
            for: makeResource(type: .asset, status: "active"),
            viewerRole: .member,
            rsvpStatus: nil,
            eventStatus: nil,
            enabledCapabilities: []
        )
        #expect(action.kind == .openBooking)
    }
}
