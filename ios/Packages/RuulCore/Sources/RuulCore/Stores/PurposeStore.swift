import Foundation
import Observation

/// `@MainActor` store for Primitiva 3 (Purpose). Holds the active
/// purposes for the current group and a small editing draft so the
/// View can bind directly. Refresh is explicit + idempotent.
@MainActor
@Observable
public final class PurposeStore {
    public private(set) var purposes: [GroupPurpose] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives a single `EditPurposeView` sheet for all three kinds —
    /// callers set `editingKind` first via `beginEditing(kind:)`.
    public var isEditPresented: Bool = false
    public var editingKind: GroupPurposeKind = .declared
    public var draftBody: String = ""
    public var draftVisibility: PurposeVisibility = .members

    private let repository: CanonicalPurposeRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalPurposeRepository) {
        self.repository = repository
    }

    // MARK: - Derived state

    public var declaredPurpose: GroupPurpose? { purpose(for: .declared) }
    public var operativePurpose: GroupPurpose? { purpose(for: .operative) }
    public var emotionalPurpose: GroupPurpose? { purpose(for: .emotional) }

    public var hasAnyPurpose: Bool { !purposes.isEmpty }

    public var canSaveDraft: Bool {
        !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func purpose(for kind: GroupPurposeKind) -> GroupPurpose? {
        purposes.first(where: { $0.kind == kind })
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if purposes.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activePurposes(groupId: groupId)
            purposes = fetched
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    /// `.task`-friendly: fetches the first time, no-ops on re-entry
    /// for the same group, refetches if the group changes.
    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !purposes.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Opens the editor for `kind`, prefilling from the existing
    /// active purpose if there is one.
    public func beginEditing(kind: GroupPurposeKind) {
        editingKind = kind
        if let existing = purpose(for: kind) {
            draftBody = existing.body
            draftVisibility = existing.visibility
        } else {
            draftBody = ""
            draftVisibility = .members
        }
        errorMessage = nil
        isEditPresented = true
    }

    /// Sends the draft via the repository. Returns `true` on success
    /// so the View can dismiss; on failure leaves the draft intact
    /// and surfaces `errorMessage`.
    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        let trimmed = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = "Escribe el propósito."
            return false
        }
        do {
            let saved = try await repository.setPurpose(
                groupId: groupId,
                kind: editingKind,
                body: trimmed,
                visibility: draftVisibility
            )
            mergeUpdated(saved)
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
            isEditPresented = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftBody = ""
        draftVisibility = .members
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Internals

    private func mergeUpdated(_ updated: GroupPurpose) {
        if let idx = purposes.firstIndex(where: { $0.kind == updated.kind }) {
            purposes[idx] = updated
        } else {
            purposes.append(updated)
        }
        // Keep canonical order so the View doesn't have to sort.
        purposes.sort { lhs, rhs in
            (Self.order(lhs.kind)) < (Self.order(rhs.kind))
        }
    }

    private static func order(_ kind: GroupPurposeKind) -> Int {
        switch kind {
        case .declared:  return 0
        case .operative: return 1
        case .emotional: return 2
        }
    }
}
