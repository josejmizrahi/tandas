import Testing
import Foundation
import RuulFeatures
@testable import Tandas

@Suite("RootShellState")
@MainActor
struct RootShellStateTests {
    @Test("defaults: selectedTab = .home, no active routes")
    func defaults() {
        let state = RootShellState()
        #expect(state.selectedTab == .home)
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("selecting a tab updates selectedTab")
    func selectTab() {
        let state = RootShellState()
        state.selectedTab = .profile
        #expect(state.selectedTab == .profile)
    }

    @Test("push(.createGroup) appends to activeRoutes")
    func pushRoute() {
        let state = RootShellState()
        state.push(.createGroup)
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("dismissTop pops the last route")
    func dismissTop() {
        let state = RootShellState()
        state.push(.createGroup)
        state.push(.joinGroup)
        state.dismissTop()
        #expect(state.activeRoutes == [.createGroup])
    }

    @Test("dismissAll clears active routes")
    func dismissAll() {
        let state = RootShellState()
        state.push(.createGroup)
        state.push(.joinGroup)
        state.dismissAll()
        #expect(state.activeRoutes.isEmpty)
    }

    @Test("contains(.createGroup) true after push")
    func containsAfterPush() {
        let state = RootShellState()
        #expect(!state.contains(.createGroup))
        state.push(.createGroup)
        #expect(state.contains(.createGroup))
    }
}
