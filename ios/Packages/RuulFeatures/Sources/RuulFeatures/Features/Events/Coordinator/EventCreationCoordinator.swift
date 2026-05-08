import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class EventCreationCoordinator {
    public var draft: EventDraft
    public private(set) var isPublishing: Bool = false
    public private(set) var error: EventError?
    public private(set) var createdEvent: Event?
    public private(set) var generatedSiblings: [Event] = []
    public let recurrenceAvailable: Bool

    public let group: Group
    private let eventRepo: any EventRepository
    private let lifecycle: EventLifecycleService
    private let analytics: EventAnalytics
    private let formStartedAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.create")

    /// `recurrenceAvailable` is true only when:
    ///  - the group has a frequency configured, AND
    ///  - this is the first event being created in the group.
    public init(
        group: Group,
        hasExistingEvents: Bool,
        suggestedDate: Date,
        eventRepo: any EventRepository,
        lifecycle: EventLifecycleService,
        analytics: EventAnalytics
    ) {
        self.group = group
        self.eventRepo = eventRepo
        self.lifecycle = lifecycle
        self.analytics = analytics
        self.recurrenceAvailable = !hasExistingEvents
            && group.frequencyType != nil
            && group.frequencyType != .unscheduled

        var draft = EventDraft.empty(suggestedDate: suggestedDate)
        draft.coverImageName = group.coverImageName ?? "sunset"
        draft.applyRules = CapabilityResolver().finesEnabled(in: group)
        self.draft = draft
        Task { await analytics.eventCreateStarted() }
    }

    public func publish() async {
        guard draft.isReadyToPublish, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            let event = try await eventRepo.createEvent(draft, in: group.id, isRecurringGenerated: false)
            createdEvent = event
            await analytics.eventCreated(
                groupId: group.id,
                hasLocation: draft.locationName != nil,
                hasDescription: !draft.description.isEmpty,
                applyRules: draft.applyRules,
                hostAssigned: draft.hostId != nil,
                recurrence: draft.recurrenceOption
            )

            // Handle recurrence option.
            if recurrenceAvailable {
                switch draft.recurrenceOption {
                case .onlyThis:
                    break
                case .nextFour:
                    let siblings = try await lifecycle.generateInitialBatch(
                        after: draft, count: 3, group: group
                    )
                    generatedSiblings = siblings
                case .untilCancelled:
                    try await lifecycle.setAutoGenerate(true, group: group)
                    await analytics.autoGenerationToggled(enabled: true)
                }
            }
        } catch let e as EventError {
            self.error = e
            log.warning("publish failed: \(e.localizedDescription)")
        } catch {
            self.error = .createFailed(error.localizedDescription)
        }
    }

    /// Called when the user backs out of CreateEventView without publishing.
    public func recordAbandon() async {
        let elapsedMs = Int(Date.now.timeIntervalSince(formStartedAt) * 1000)
        await analytics.eventCreateAbandoned(timeMs: elapsedMs)
    }

    public func clearError() { error = nil }
}
