import Foundation
import Observation

/// `@MainActor` store for Primitiva 21 (Ritual). Caches the ritual
/// series list per group + drives the `CreateRitualSheet` and
/// `EditRitualSheet` via drafts.
@MainActor
@Observable
public final class RitualsStore {
    public private(set) var rituals: [GroupResourceSeries] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    // MARK: - Create draft

    public var isCreatePresented: Bool = false
    public var createDraftMarker: RitualMarkerKind = .weeklyMeeting
    public var createDraftCadence: RitualCadence = .weekly
    public var createDraftMeaning: String = ""
    public var createDraftStartsOn: Date = Date()
    public var createDraftHasEndDate: Bool = false
    public var createDraftEndsOn: Date?
    public private(set) var createDraftErrorMessage: String?

    // MARK: - Edit draft

    public var isEditPresented: Bool = false
    public var editDraftSeriesId: UUID?
    public var editDraftMarker: RitualMarkerKind = .weeklyMeeting
    public var editDraftMeaning: String = ""
    public var editDraftHasEndDate: Bool = false
    public var editDraftEndsOn: Date?
    public private(set) var editDraftErrorMessage: String?

    private let repository: CanonicalRitualsRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalRitualsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasRituals: Bool { !rituals.isEmpty }

    public var canSaveCreateDraft: Bool {
        !createDraftMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSaveEditDraft: Bool {
        guard editDraftSeriesId != nil else { return false }
        return !editDraftMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - List intents

    public func refresh(groupId: UUID) async {
        if rituals.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            rituals = try await repository.listRituals(groupId: groupId)
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !rituals.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    // MARK: - Create

    public func beginCreating() {
        createDraftMarker = .weeklyMeeting
        createDraftCadence = .weekly
        createDraftMeaning = ""
        createDraftStartsOn = Date()
        createDraftHasEndDate = false
        createDraftEndsOn = nil
        createDraftErrorMessage = nil
        isCreatePresented = true
    }

    @discardableResult
    public func saveCreateDraft(groupId: UUID) async -> Bool {
        let trimmed = createDraftMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            createDraftErrorMessage = String(localized: L10n.Rituals.meaningRequired)
            return false
        }
        let endsOn: Date? = createDraftHasEndDate ? createDraftEndsOn : nil
        if let endsOn, endsOn <= createDraftStartsOn {
            createDraftErrorMessage = String(localized: L10n.Rituals.endsAfterStart)
            return false
        }
        do {
            _ = try await repository.createRitual(
                groupId: groupId,
                cadence: createDraftCadence,
                startsOn: createDraftStartsOn,
                endsOn: endsOn,
                markerKind: createDraftMarker,
                meaning: trimmed
            )
            await refresh(groupId: groupId)
            isCreatePresented = false
            createDraftErrorMessage = nil
            return true
        } catch {
            createDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Edit

    public func beginEditing(_ ritual: GroupResourceSeries) {
        editDraftSeriesId = ritual.id
        editDraftMarker = ritual.ritualMarkerKind ?? .weeklyMeeting
        editDraftMeaning = ritual.ritualMeaning ?? ""
        editDraftHasEndDate = ritual.endsOn != nil
        editDraftEndsOn = ritual.endsOn
        editDraftErrorMessage = nil
        isEditPresented = true
    }

    @discardableResult
    public func saveEditDraft(groupId: UUID) async -> Bool {
        guard let seriesId = editDraftSeriesId else {
            editDraftErrorMessage = String(localized: L10n.Rituals.meaningRequired)
            return false
        }
        let trimmed = editDraftMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editDraftErrorMessage = String(localized: L10n.Rituals.meaningRequired)
            return false
        }
        let endsOn: Date? = editDraftHasEndDate ? editDraftEndsOn : nil
        do {
            try await repository.updateRitual(
                seriesId: seriesId,
                meaning: trimmed,
                markerKind: editDraftMarker,
                endsOn: endsOn
            )
            await refresh(groupId: groupId)
            isEditPresented = false
            editDraftErrorMessage = nil
            return true
        } catch {
            editDraftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func endRitual(_ seriesId: UUID, groupId: UUID) async -> Bool {
        do {
            try await repository.endRitual(seriesId: seriesId)
            await refresh(groupId: groupId)
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
        createDraftErrorMessage = nil
        editDraftErrorMessage = nil
    }
}
