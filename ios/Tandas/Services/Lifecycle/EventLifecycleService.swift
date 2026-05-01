import Foundation
import OSLog

/// Coordinates event status transitions + recurring event generation.
///
/// V1 strategy (per plan §5.4):
/// - Recurring generation is **client-triggered** as the primary path. When
///   a host calls `closeEvent`, this service decides whether to also create
///   the next event in the series.
/// - The `auto-generate-events` cron edge function is the safety net for
///   hosts who never close events.
@MainActor
final class EventLifecycleService {
    private let eventRepo: any EventRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.lifecycle")

    init(eventRepo: any EventRepository) {
        self.eventRepo = eventRepo
    }

    /// Closes the event without firing the rule engine (V1).
    /// If the event is recurring-generated OR the group has
    /// `auto_generate_events == true`, also schedules the next occurrence.
    func closeEvent(_ event: Event, in group: Group, autoGenerateEnabled: Bool) async throws -> Event {
        let closed = try await eventRepo.closeEvent(event.id)
        if shouldGenerateNext(event: event, group: group, autoGenerateEnabled: autoGenerateEnabled) {
            await generateNextEvent(after: event, in: group)
        }
        return closed
    }

    /// Generate next N occurrences immediately (used by RecurrenceOption.nextFour).
    func generateInitialBatch(after firstDraft: EventDraft, count: Int, group: Group) async throws -> [Event] {
        guard count > 0,
              let frequency = group.frequencyType,
              frequency != .unscheduled
        else { return [] }
        let config = group.frequencyConfig ?? .empty
        var created: [Event] = []
        var lastDate = firstDraft.startsAt
        for _ in 0..<count {
            guard let next = EventScheduler.nextDate(after: lastDate, type: frequency, config: config) else { break }
            var nextDraft = firstDraft
            nextDraft.startsAt = next
            // Title gets a date suffix so they're distinguishable.
            nextDraft.title = "\(firstDraft.title) — \(next.ruulShortDate)"
            do {
                let event = try await eventRepo.createEvent(nextDraft, in: group.id, isRecurringGenerated: true)
                created.append(event)
                lastDate = next
            } catch {
                log.warning("batch generate failed at \(next): \(error.localizedDescription)")
                break
            }
        }
        return created
    }

    /// Enable/disable auto-generation flag on the group.
    func setAutoGenerate(_ enabled: Bool, group: Group) async throws {
        try await eventRepo.setAutoGenerate(groupId: group.id, enabled: enabled)
    }

    // MARK: - Helpers

    private func shouldGenerateNext(event: Event, group: Group, autoGenerateEnabled: Bool) -> Bool {
        guard let frequency = group.frequencyType, frequency != .unscheduled else { return false }
        return event.isRecurringGenerated || autoGenerateEnabled
    }

    private func generateNextEvent(after event: Event, in group: Group) async {
        guard let frequency = group.frequencyType, frequency != .unscheduled else { return }
        let config = group.frequencyConfig ?? .empty
        guard let nextDate = EventScheduler.nextDate(after: event.startsAt, type: frequency, config: config) else { return }

        var draft = EventDraft.empty(suggestedDate: nextDate)
        draft.title = event.title
        draft.coverImageName = event.coverImageName
        draft.coverImageURL = event.coverImageURL
        draft.description = event.description ?? ""
        draft.durationMinutes = event.durationMinutes
        draft.locationName = event.locationName
        draft.locationLat = event.locationLat
        draft.locationLng = event.locationLng
        draft.applyRules = event.applyRules

        do {
            _ = try await eventRepo.createEvent(draft, in: group.id, isRecurringGenerated: true)
        } catch {
            log.warning("auto-generate next event failed: \(error.localizedDescription)")
        }
    }
}
