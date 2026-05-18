import Foundation
import RuulCore

/// Async bootstrap for `EventDetailHost`: builds the
/// `EventDetailCoordinator`, loads enabled capabilities, hydrates
/// attention actions, computes governance gates. Pure async work —
/// no SwiftUI references.
///
/// Returns ready-to-use state via the `Result`. Caller (the
/// `EventDetailHost` view) wires the result to its `@State`
/// properties. Three previously-parallel `.task` modifiers in the
/// host become one task that uses `async let` for parallelism.
@MainActor
public struct EventDetailBootstrap {
    public let app: AppState
    public let event: Event
    public let group: RuulCore.Group
    public let currentUserId: UUID
    public let memberDirectory: [UUID: MemberWithProfile]

    public init(
        app: AppState,
        event: Event,
        group: RuulCore.Group,
        currentUserId: UUID,
        memberDirectory: [UUID: MemberWithProfile]
    ) {
        self.app = app
        self.event = event
        self.group = group
        self.currentUserId = currentUserId
        self.memberDirectory = memberDirectory
    }

    public struct Result {
        public let coordinator: EventDetailCoordinator
        public let enabledCapabilities: Set<String>
        public let attentionActions: [UserAction]
        public let canIssueManualFine: Bool
    }

    public func run() async -> Result {
        let coordinator = makeCoordinator()

        async let caps: Set<String> = loadCapabilities()
        async let attention: [UserAction] = loadAttentionActions()
        async let canIssue: Bool = computeCanIssueManualFine()

        return Result(
            coordinator: coordinator,
            enabledCapabilities: await caps,
            attentionActions: await attention,
            canIssueManualFine: await canIssue
        )
    }

    private func makeCoordinator() -> EventDetailCoordinator {
        EventDetailCoordinator(
            event: event,
            group: group,
            userId: currentUserId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            checkInRepo: app.checkInRepo,
            lifecycle: app.eventLifecycle,
            notifications: app.notifications,
            walletService: app.walletService,
            analytics: EventAnalytics(analytics: app.analytics),
            realtimeFactory: app.realtimeFactory,
            systemEvents: app.systemEventEmitter,
            notificationDispatcher: app.eventNotificationDispatcher
        )
    }

    private func loadCapabilities() async -> Set<String> {
        let caps = (try? await app.resourceCapabilityRepo.list(resourceId: event.id)) ?? []
        return Set(caps.filter { $0.enabled }.map { $0.capabilityBlockId })
    }

    private func loadAttentionActions() async -> [UserAction] {
        let pending = (try? await app.userActionRepo.pending(
            userId: currentUserId,
            groupId: group.id
        )) ?? []
        return pending.filter { $0.referenceId == event.id && $0.resolvedAt == nil }
    }

    private func computeCanIssueManualFine() async -> Bool {
        let me = memberDirectory[currentUserId]?.member
            ?? Self.fallbackMember(userId: currentUserId, groupId: group.id)
        do {
            let decision = try await app.governance.canPerform(
                .issueManualFine,
                member: me,
                in: group,
                context: nil
            )
            if case .allowed = decision { return true }
            return false
        } catch {
            return false
        }
    }

    /// Synthetic inactive member used when the directory hasn't surfaced
    /// the current user yet (anon sessions, just-joined races). Forces
    /// the fail-closed governance gate to deny — manual fine CTA stays
    /// hidden until the next directory refresh promotes the row.
    static func fallbackMember(userId: UUID, groupId: UUID) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            roles: [.member],
            active: false,
            joinedAt: .now
        )
    }
}
