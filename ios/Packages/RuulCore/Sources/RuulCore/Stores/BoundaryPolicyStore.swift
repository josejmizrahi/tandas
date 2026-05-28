import Foundation
import Observation

/// `@MainActor` store for Primitiva 2 (Boundary) policy. Caches the
/// current policy + drives the edit sheet via a draft. Save round-trips
/// the canonical re-read so iOS always reflects backend truth.
@MainActor
@Observable
public final class BoundaryPolicyStore {
    public private(set) var policy: GroupBoundaryPolicy?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    // MARK: - Edit draft

    public var isEditPresented: Bool = false
    public var draftEntryMode: BoundaryEntryMode = .inviteOnly
    public var draftWhoCanInvite: BoundaryInviterScope = .anyMember
    public var draftRequiresApproval: Bool = false
    public var draftExitMode: BoundaryExitMode = .free
    public var draftNotes: String = ""
    public private(set) var draftErrorMessage: String?

    private let repository: CanonicalBoundaryRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalBoundaryRepository) {
        self.repository = repository
    }

    // MARK: - List intents

    public func refresh(groupId: UUID) async {
        if policy == nil || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            policy = try await repository.policy(groupId: groupId)
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
        if loadedGroupId == groupId, policy != nil {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    // MARK: - Edit

    public func beginEditing() {
        let current = policy ?? GroupBoundaryPolicy(groupId: loadedGroupId ?? UUID())
        draftEntryMode = current.entryMode
        draftWhoCanInvite = current.whoCanInvite
        draftRequiresApproval = current.requiresApproval
        draftExitMode = current.exitMode
        draftNotes = current.notes ?? ""
        draftErrorMessage = nil
        isEditPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        do {
            let updated = try await repository.setPolicy(
                groupId: groupId,
                entryMode: draftEntryMode,
                whoCanInvite: draftWhoCanInvite,
                requiresApproval: draftRequiresApproval,
                exitMode: draftExitMode,
                notes: draftNotes
            )
            policy = updated
            isEditPresented = false
            draftErrorMessage = nil
            return true
        } catch {
            draftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
        draftErrorMessage = nil
    }
}
