import Foundation
import Observation

/// `@MainActor` store for Primitiva 9 (Contribuciones). Holds the
/// active list per group + drives the `LogContributionSheet` form via
/// a draft.
@MainActor
@Observable
public final class ContributionsStore {
    public private(set) var contributions: [GroupContribution] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `LogContributionSheet`.
    public var isLogPresented: Bool = false
    public var draftType: ContributionType = .care
    public var draftTitle: String = ""
    public var draftDescription: String = ""
    public var draftAmountText: String = ""
    public var draftUnit: String = ""

    private let repository: CanonicalContributionsRepository
    private var loadedKey: CacheKey?

    public init(repository: CanonicalContributionsRepository) {
        self.repository = repository
    }

    private struct CacheKey: Equatable {
        let groupId: UUID
        let membershipId: UUID?
        let resourceId: UUID?
    }

    // MARK: - Derived

    public var hasContributions: Bool { !contributions.isEmpty }

    public var contributionsByType: [ContributionType: [GroupContribution]] {
        Dictionary(grouping: contributions, by: \.type)
    }

    /// Title or description must be non-blank. Amount + unit must be
    /// either both blank or both filled.
    public var canSaveDraft: Bool {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && d.isEmpty { return false }
        let amount = parsedAmount
        let unit = draftUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        if amount != nil && unit.isEmpty { return false }
        if amount == nil && !unit.isEmpty { return false }
        if let amount, amount <= 0 { return false }
        return true
    }

    private var parsedAmount: Decimal? {
        let normalized = draftAmountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized)
    }

    // MARK: - Intents

    public func refresh(groupId: UUID, membershipId: UUID? = nil, resourceId: UUID? = nil) async {
        let key = CacheKey(groupId: groupId, membershipId: membershipId, resourceId: resourceId)
        if contributions.isEmpty || loadedKey != key {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeContributions(
                groupId: groupId,
                membershipId: membershipId,
                resourceId: resourceId
            )
            contributions = fetched
            phase = .loaded
            loadedKey = key
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID, membershipId: UUID? = nil, resourceId: UUID? = nil) async {
        let key = CacheKey(groupId: groupId, membershipId: membershipId, resourceId: resourceId)
        if loadedKey == key, !contributions.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId, membershipId: membershipId, resourceId: resourceId)
    }

    public func beginLogging(type: ContributionType? = nil) {
        draftType = type ?? .care
        draftTitle = ""
        draftDescription = ""
        draftAmountText = ""
        draftUnit = ""
        errorMessage = nil
        isLogPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && desc.isEmpty {
            errorMessage = String(localized: L10n.Contributions.titleOrDescriptionRequired)
            return false
        }
        let amount = parsedAmount
        let unit = draftUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        if (amount == nil) != unit.isEmpty {
            // exactly-one-side-set
            errorMessage = String(localized: L10n.Contributions.amountUnitPaired)
            return false
        }
        if let amount, amount <= 0 {
            errorMessage = String(localized: L10n.Contributions.amountPositive)
            return false
        }
        do {
            _ = try await repository.log(
                groupId: groupId,
                type: draftType,
                title: title.isEmpty ? nil : title,
                description: desc.isEmpty ? nil : desc,
                amount: amount,
                unit: unit.isEmpty ? nil : unit
            )
            await refresh(groupId: groupId)
            isLogPresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftType = .care
        draftTitle = ""
        draftDescription = ""
        draftAmountText = ""
        draftUnit = ""
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
