import Foundation
import Observation
import OSLog

@Observable @MainActor
final class EventCreationCoordinator {
    var draft: EventDraft
    private(set) var isPublishing: Bool = false
    private(set) var error: EventError?
    private(set) var createdEvent: Event?
    private(set) var generatedSiblings: [Event] = []
    let recurrenceAvailable: Bool

    let group: Group
    private let eventRepo: any EventRepository
    private let lifecycle: EventLifecycleService
    private let analytics: EventAnalytics
    private let formStartedAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.create")

    /// `recurrenceAvailable` is true only when:
    ///  - the group has a frequency configured, AND
    ///  - this is the first event being created in the group.
    init(
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
        draft.applyRules = group.finesEnabled
        self.draft = draft
        Task { await analytics.eventCreateStarted() }
    }

    func publish() async {
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
    func recordAbandon() async {
        let elapsedMs = Int(Date.now.timeIntervalSince(formStartedAt) * 1000)
        await analytics.eventCreateAbandoned(timeMs: elapsedMs)
    }

    func clearError() { error = nil }
}
