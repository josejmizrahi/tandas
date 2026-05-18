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
        // RSVPSectionView never declared tabId — must default to "overview"
        #expect(RSVPSectionView.definition.tabId == "overview")
    }
}
