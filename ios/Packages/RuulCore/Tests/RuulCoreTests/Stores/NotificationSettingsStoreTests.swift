import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("NotificationSettingsStore")
struct NotificationSettingsStoreTests {

    private let groupId = UUID()

    private func makeStore(
        seed: [NotificationPreferenceRow] = []
    ) async -> (NotificationSettingsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setMyNotificationPreferencesStub(.success(seed))
        let repo = CanonicalNotificationsRepository(rpc: mock)
        return (NotificationSettingsStore(repository: repo), mock)
    }

    @Test("Missing override key defaults to enabled=true")
    func defaultsToEnabled() async {
        let (store, _) = await makeStore()
        await store.refresh(groupId: groupId)
        #expect(store.isEnabled(category: .decisions, channel: .push))
        #expect(store.isEnabled(category: .sanctions, channel: .inApp))
    }

    @Test("Refresh loads overrides and flips isEnabled accordingly")
    func refreshLoadsOverrides() async {
        let row = NotificationPreferenceRow(
            groupId: groupId, category: "decisions", channel: "push", enabled: false
        )
        let (store, _) = await makeStore(seed: [row])
        await store.refresh(groupId: groupId)
        #expect(store.isEnabled(category: .decisions, channel: .push) == false)
        // Untouched categories still default to true.
        #expect(store.isEnabled(category: .sanctions, channel: .push))
    }

    @Test("setEnabled optimistically updates + fires backend upsert")
    func setEnabledOptimistic() async {
        let (store, mock) = await makeStore()
        await store.refresh(groupId: groupId)

        let ok = await store.setEnabled(
            groupId: groupId,
            category: .money,
            channel: .inApp,
            enabled: false
        )
        #expect(ok)
        #expect(store.isEnabled(category: .money, channel: .inApp) == false)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .setNotificationPreference(let input) = call {
                return input.pGroupId == groupId
                    && input.pCategory == "money"
                    && input.pChannel == "in_app"
                    && input.pEnabled == false
            }
            return false
        })
    }

    @Test("setEnabled reverts on backend failure")
    func setEnabledReverts() async {
        let mock = MockRuulRPCClient()
        await mock.setMyNotificationPreferencesStub(.success([]))
        await mock.setSetNotificationPreferenceStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = NotificationSettingsStore(repository: CanonicalNotificationsRepository(rpc: mock))
        await store.refresh(groupId: groupId)

        let ok = await store.setEnabled(
            groupId: groupId,
            category: .decisions,
            channel: .push,
            enabled: false
        )
        #expect(ok == false)
        // Optimistic flip reverted back to default (true).
        #expect(store.isEnabled(category: .decisions, channel: .push))
        #expect(store.errorMessage != nil)
    }
}
