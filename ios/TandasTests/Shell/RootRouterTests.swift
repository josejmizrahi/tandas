import Testing
import Foundation
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("RootRouter")
@MainActor
struct RootRouterTests {
    private func makeRouter() -> (RootRouter, RootShellState) {
        let state = RootShellState()
        let router = RootRouter(state: state)
        return (router, state)
    }

    @Test("selectTab updates state.selectedTab")
    func selectTab() {
        let (router, state) = makeRouter()
        router.selectTab(.profile)
        #expect(state.selectedTab == .profile)
    }

    @Test("present(.createGroup) pushes route")
    func present() {
        let (router, state) = makeRouter()
        router.present(.createGroup)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("intercept .create tab with active group opens createCover route, does not change tab")
    func createInterceptWithActiveGroup() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.create, hasActiveGroup: true)
        #expect(state.selectedTab == .home, "tab unchanged")
        #expect(state.activeRoutes == [.createCover])
    }

    @Test("intercept .create with no group routes to createGroup")
    func createInterceptNoGroup() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.create, hasActiveGroup: false)
        #expect(state.selectedTab == .home)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("non-create tab selection updates selectedTab normally")
    func normalTab() {
        let (router, state) = makeRouter()
        router.handleTabSelection(.group, hasActiveGroup: true)
        #expect(state.selectedTab == .group)
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("handleEventDeepLink pushes eventDetail route")
    func eventDeepLink() {
        let (router, state) = makeRouter()
        let eventID = UUID()
        // EventDeepLink.init(eventId:) — note lowercase 'i' in eventId
        let link = EventDeepLink(eventId: eventID)
        router.handle(eventDeepLink: link)
        #expect(state.activeRoutes == [.eventDetail(eventID)])
    }

    @Test("dismissTop is idempotent on empty stack")
    func dismissEmpty() {
        let (router, state) = makeRouter()
        router.dismissTop()
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("openResource(id:) pushes eventDetail route")
    func openResource() {
        let (router, state) = makeRouter()
        let id = UUID()
        router.openResource(id: id)
        #expect(state.activeRoutes == [.eventDetail(id)])
    }
}
