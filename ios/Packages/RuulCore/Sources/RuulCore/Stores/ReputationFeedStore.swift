import Foundation
import Observation

/// `@MainActor` store for the group-wide reputation feed (Primitiva
/// 12, C4). Separate from `ReputationStore` (per-member) so the two
/// surfaces refresh independently. Also drives the
/// `RecordReputationEventSheet` form via a draft.
@MainActor
@Observable
public final class ReputationFeedStore {
    public private(set) var events: [GroupReputationEvent] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `RecordReputationEventSheet`.
    public var isRecordPresented: Bool = false
    public var draftSubjectMembershipId: UUID?
    public var draftKind: ReputationKind = .careShown
    public var draftReason: String = ""
    public var draftVisibility: ReputationVisibility = .members

    private let repository: CanonicalReputationRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalReputationRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var isEmpty: Bool { events.isEmpty }

    public var canSaveDraft: Bool {
        draftSubjectMembershipId != nil
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if events.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.groupFeed(groupId: groupId)
            events = fetched
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
        if loadedGroupId == groupId, !events.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginRecording(defaultSubject: UUID? = nil) {
        draftSubjectMembershipId = defaultSubject
        draftKind = .careShown
        draftReason = ""
        draftVisibility = .members
        errorMessage = nil
        isRecordPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        guard let subject = draftSubjectMembershipId else {
            errorMessage = String(localized: L10n.RecordReputation.subjectRequired)
            return false
        }
        do {
            _ = try await repository.record(
                groupId: groupId,
                subjectMembershipId: subject,
                kind: draftKind,
                reason: draftReason,
                visibility: draftVisibility
            )
            await refresh(groupId: groupId)
            isRecordPresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftSubjectMembershipId = nil
        draftKind = .careShown
        draftReason = ""
        draftVisibility = .members
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
