import Foundation
import Observation
import OSLog

/// Coordinator for editing an existing event. Mirrors EventCreationCoordinator
/// but seeds the draft from the current event and submits via
/// `EventRepository.updateEvent(_:patch:)` rather than create.
///
/// Builds an `EventPatch` containing only the fields that actually changed
/// vs. the original — minimizes payload + avoids triggering unnecessary
/// PostgREST notifications on no-op updates.
@Observable @MainActor
final class EventEditCoordinator {
    var draft: EventDraft
    private(set) var isSaving: Bool = false
    private(set) var error: EventError?
    private(set) var updatedEvent: Event?

    let group: Group
    let originalEvent: Event
    private let eventRepo: any EventRepository
    private let analytics: EventAnalytics
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.edit")

    init(
        event: Event,
        group: Group,
        eventRepo: any EventRepository,
        analytics: EventAnalytics
    ) {
        self.originalEvent = event
        self.group = group
        self.eventRepo = eventRepo
        self.analytics = analytics
        self.draft = EventDraft(
            title: event.title,
            coverImageName: event.coverImageName,
            coverImageURL: event.coverImageURL,
            description: event.description ?? "",
            startsAt: event.startsAt,
            durationMinutes: event.durationMinutes,
            locationName: event.locationName,
            locationLat: event.locationLat,
            locationLng: event.locationLng,
            hostId: event.hostId,
            applyRules: event.applyRules,
            recurrenceOption: .onlyThis      // unused on edit, no recurrence card shown
        )
    }

    func save() async {
        guard draft.isReadyToPublish, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let patch = computePatch()
        if patch == EventPatch() {
            // No-op edit — just dismiss without RPC roundtrip.
            updatedEvent = originalEvent
            return
        }

        do {
            updatedEvent = try await eventRepo.updateEvent(originalEvent.id, patch: patch)
        } catch let e as EventError {
            self.error = e
            log.warning("save failed: \(e.localizedDescription)")
        } catch {
            self.error = .updateFailed(error.localizedDescription)
        }
    }

    func clearError() { error = nil }

    // MARK: - Diff helper

    /// Build an EventPatch with only fields that differ from the original.
    private func computePatch() -> EventPatch {
        var patch = EventPatch()
        if draft.title != originalEvent.title { patch.title = draft.title }
        if draft.description != (originalEvent.description ?? "") {
            patch.description = draft.description.isEmpty ? "" : draft.description
        }
        if draft.coverImageName != originalEvent.coverImageName {
            patch.coverImageName = draft.coverImageName
        }
        if draft.coverImageURL != originalEvent.coverImageURL {
            patch.coverImageURL = draft.coverImageURL
        }
        if abs(draft.startsAt.timeIntervalSince(originalEvent.startsAt)) > 1 {
            patch.startsAt = draft.startsAt
        }
        if draft.durationMinutes != originalEvent.durationMinutes {
            patch.durationMinutes = draft.durationMinutes
        }
        if draft.locationName != originalEvent.locationName {
            patch.locationName = draft.locationName
        }
        if draft.locationLat != originalEvent.locationLat {
            patch.locationLat = draft.locationLat
        }
        if draft.locationLng != originalEvent.locationLng {
            patch.locationLng = draft.locationLng
        }
        if draft.hostId != originalEvent.hostId {
            patch.hostId = draft.hostId
        }
        if draft.applyRules != originalEvent.applyRules {
            patch.applyRules = draft.applyRules
        }
        return patch
    }
}
