import Testing
import SwiftUI
import RuulCore
@testable import RuulFeatures

@Suite("CapabilitySection.tabId")
@MainActor
struct CapabilitySectionTabIdTests {
    @Test("default tabId is 'overview' when not specified")
    func defaultTabIdIsOverview() {
        let section = CapabilitySection(
            id: "test",
            priority: 100,
            isEnabledFor: { _ in true },
            render: { _ in AnyView(EmptyView()) }
        )
        #expect(section.tabId == "overview")
    }

    @Test("explicit tabId is preserved")
    func explicitTabIdPreserved() {
        let section = CapabilitySection(
            id: "test",
            priority: 100,
            tabId: "rules",
            isEnabledFor: { _ in true },
            render: { _ in AnyView(EmptyView()) }
        )
        #expect(section.tabId == "rules")
    }

    @Test("RulesSectionView.definition.tabId == rules")
    func rulesSectionTab() {
        #expect(RulesSectionView.definition.tabId == "rules")
    }

    @Test("ResourcesUsedSectionView.definition.tabId == connections")
    func resourcesUsedSectionTab() {
        #expect(ResourcesUsedSectionView.definition.tabId == "connections")
    }

    @Test("ActivitySectionView.definition.tabId == activity")
    func activitySectionTab() {
        #expect(ActivitySectionView.definition.tabId == "activity")
    }

    @Test("a sample default section still reports overview")
    func defaultSectionStillOverview() {
        // DescriptionSectionView never declared tabId — must default to
        // "overview". RSVP used to anchor this test but moved to "people"
        // in Slice 2A (see peopleSectionsTab below).
        #expect(DescriptionSectionView.definition.tabId == "overview")
    }

    // MARK: - Slice 2A (Plans/Active/HumanLayerSimplification.md §C.1)
    // People-domain sections now route to the .people tab. The tab is
    // content-gated in UniversalResourceDetailView.visibleTabs so it
    // only appears when at least one of these sections is enabled.

    @Test("RSVPSectionView.definition.tabId == people")
    func rsvpSectionTab() {
        #expect(RSVPSectionView.definition.tabId == "people")
    }

    @Test("CheckInSectionView.definition.tabId == people")
    func checkInSectionTab() {
        #expect(CheckInSectionView.definition.tabId == "people")
    }

    @Test("HostActionsSectionView.definition.tabId == people")
    func hostActionsSectionTab() {
        #expect(HostActionsSectionView.definition.tabId == "people")
    }

    @Test("AssetCustodySection.definition.tabId == people")
    func assetCustodySectionTab() {
        #expect(AssetCustodySection.definition.tabId == "people")
    }

    @Test("ParticipantsSectionView.definition.tabId == people")
    func participantsSectionTab() {
        #expect(ParticipantsSectionView.definition.tabId == "people")
    }

    @Test("AttendanceSectionView.definition.tabId == people")
    func attendanceSectionTab() {
        #expect(AttendanceSectionView.definition.tabId == "people")
    }

    @Test("GuestAccessSectionView.definition.tabId == people")
    func guestAccessSectionTab() {
        #expect(GuestAccessSectionView.definition.tabId == "people")
    }

    @Test("AssignmentSectionView.definition.tabId == people")
    func assignmentSectionTab() {
        #expect(AssignmentSectionView.definition.tabId == "people")
    }

    @Test("DelegationSectionView.definition.tabId == people")
    func delegationSectionTab() {
        #expect(DelegationSectionView.definition.tabId == "people")
    }

    // Verify a money-domain section did NOT move to .people in 2A
    // (Slice 2B moves these). Guards against accidental over-routing.
    @Test("MoneySectionView stays on overview until Slice 2B")
    func moneySectionStaysOverview() {
        #expect(MoneySectionView.definition.tabId == "overview")
    }
}
