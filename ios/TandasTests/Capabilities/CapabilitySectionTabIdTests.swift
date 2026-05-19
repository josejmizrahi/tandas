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

    // MARK: - Slice 2B (Plans/Active/HumanLayerSimplification.md §F)
    // Money-domain sections now route to the .money tab. Same content-
    // gated visibility pattern as .people. AssetOwnershipSection stays
    // in overview — it mixes owner (people) + valuation (money) and
    // would need a section split rather than a simple route move.

    @Test("MoneySectionView.definition.tabId == money")
    func moneySectionTab() {
        #expect(MoneySectionView.definition.tabId == "money")
    }

    @Test("FundBalanceSection.definition.tabId == money")
    func fundBalanceSectionTab() {
        #expect(FundBalanceSection.definition.tabId == "money")
    }

    @Test("ValuationSectionView.definition.tabId == money")
    func valuationSectionTab() {
        #expect(ValuationSectionView.definition.tabId == "money")
    }

    @Test("ConsequenceSectionView.definition.tabId == money")
    func consequenceSectionTab() {
        // Fines / "MULTAS APLICADAS" → money-domain per
        // HumanLayerSimplification.md §A.1 ("fines" listed under Money).
        #expect(ConsequenceSectionView.definition.tabId == "money")
    }

    // Guard: AssetOwnershipSection deferred — still on overview.
    @Test("AssetOwnershipSection stays on overview (deferred)")
    func assetOwnershipStaysOverview() {
        #expect(AssetOwnershipSection.definition.tabId == "overview")
    }
}
