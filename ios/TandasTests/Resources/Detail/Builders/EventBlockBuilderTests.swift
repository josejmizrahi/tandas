import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("EventBlockBuilder")
@MainActor
struct EventBlockBuilderTests {

    @Test("guest with no RSVP → state is actionable, RSVP block is obligation")
    func guestNoRSVP() {
        let builder = EventBlockBuilder()
        let snapshot = TestFixtures.scheduledEventSnapshot(rsvpForViewer: nil)
        let viewer   = TestFixtures.guestViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .actionable)
        #expect(blocks.state.headline.lowercased().contains("confirma"))
        let rsvp = blocks.capabilities.first { $0.id == "rsvp" }
        #expect(rsvp != nil)
        #expect(rsvp?.isViewerObligation == true)
        #expect(blocks.state.primaryAction?.kind == .rsvpConfirm)
    }

    @Test("host sees 'anfitrión' headline with no primary action")
    func hostHeadline() {
        let builder  = EventBlockBuilder()
        let snapshot = TestFixtures.scheduledEventSnapshot(hostIsViewer: true)
        let viewer   = TestFixtures.hostViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .actionable)
        #expect(blocks.state.headline.lowercased().contains("anfitr"))
        #expect(blocks.state.primaryAction == nil)
    }

    @Test("closed event renders terminal urgency + no primary action")
    func closedEvent() {
        let builder  = EventBlockBuilder()
        let snapshot = TestFixtures.closedEventSnapshot()
        let viewer   = TestFixtures.guestViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .terminal)
        #expect(blocks.state.primaryAction == nil)
    }

    @Test("location block always included (Addendum E.5): emptyPrompt when no location")
    func locationBlockAlwaysIncluded() {
        let builder  = EventBlockBuilder()
        let snapshot = TestFixtures.scheduledEventSnapshot(locationName: nil)
        let viewer   = TestFixtures.guestViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        let loc = blocks.capabilities.first { $0.id == "location" }
        #expect(loc != nil)
        #expect(loc?.layoutKind == .emptyPrompt)
    }

    @Test("location block summaryFacts when location name present")
    func locationBlockWithName() {
        let builder  = EventBlockBuilder()
        let snapshot = TestFixtures.scheduledEventSnapshot(locationName: "Casa de Ana")
        let viewer   = TestFixtures.guestViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        let loc = blocks.capabilities.first { $0.id == "location" }
        #expect(loc?.layoutKind == .summaryFacts)
        #expect(loc?.payload.facts.first?.value == "Casa de Ana")
        #expect(loc?.openDestinationId == "location.editor")
    }

    @Test("rotation block emptyPrompt when no config")
    func rotationUnconfigured() {
        let builder  = EventBlockBuilder()
        let snapshot = TestFixtures.scheduledEventSnapshot(rotationConfig: nil)
        let viewer   = TestFixtures.guestViewerContext()
        let blocks   = builder.build(source: snapshot, viewer: viewer, now: TestFixtures.now)

        let rot = blocks.capabilities.first { $0.id == "rotation" }
        #expect(rot != nil)
        #expect(rot?.layoutKind == .emptyPrompt)
        #expect(rot?.openDestinationId == "rotation.participants")
    }

    @Test("rotation block summaryFacts with correct cycle_offset formula (Addendum E.5)")
    func rotationCycleOffsetFormula() {
        let p1 = UUID()
        let p2 = UUID()
        let p3 = UUID()
        let participants = [p1, p2, p3]
        let dir: [UUID: MemberWithProfile] = [
            p1: MemberWithProfile(member: makeMember(userId: p1, name: "Ana"),    profile: nil),
            p2: MemberWithProfile(member: makeMember(userId: p2, name: "Bruno"),  profile: nil),
            p3: MemberWithProfile(member: makeMember(userId: p3, name: "Carlos"), profile: nil)
        ]
        let rotation = RotationSnapshotInput(
            participants: participants,
            order: "sequential",
            replacementPolicy: "skip_to_next",
            cycleOffset: 1    // offset shifts cursor
        )
        let event = Event(
            id: UUID(),
            groupId: TestFixtures.groupId,
            title: "Test",
            startsAt: TestFixtures.now.addingTimeInterval(86_400),
            hostId: TestFixtures.hostUserId,
            status: .upcoming,
            createdAt: TestFixtures.now
        )
        let snapshot = EventDetailSnapshot(
            event: event,
            myRSVP: nil,
            rotationConfig: rotation,
            cycleNumber: 3,     // cycle=3, offset=1, count=3
            memberDirectory: dir,
            viewerIsHost: false
        )
        // Formula: ((3-1-1) % 3 + 3) % 3 = (1 % 3 + 3) % 3 = 4 % 3 = 1 → p2 (Bruno)
        let blocks = EventBlockBuilder().build(
            source: snapshot,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        let rot = blocks.capabilities.first { $0.id == "rotation" }
        #expect(rot?.layoutKind == .summaryFacts)
        let nextHostFact = rot?.payload.facts.first { $0.id == "next_host" }
        #expect(nextHostFact?.value == "Bruno")
    }
}

// MARK: - Helpers

private func makeMember(userId: UUID, name: String) -> Member {
    Member(
        id: UUID(),
        groupId: TestFixtures.groupId,
        userId: userId,
        displayNameOverride: name,
        joinedAt: TestFixtures.now
    )
}
