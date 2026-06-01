import Foundation
import Observation

/// `@MainActor` store for Primitiva 11 (Sanciones). Caches the active
/// sanctions list per group + drives the `IssueSanctionSheet` via a
/// draft. Mirrors the PurposeStore/DecisionRulesStore shape so the
/// View layer stays predictable.
@MainActor
@Observable
public final class SanctionsStore {
    public private(set) var sanctions: [GroupSanction] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    /// D24P10B — exponer outcome para UI (decisionOpened banner, etc).
    public private(set) var lastGovernanceOutcome: ActionOutcome?

    /// Drives the `IssueSanctionSheet`.
    public var isIssuePresented: Bool = false
    public var draftTargetMembershipId: UUID?
    public var draftKind: SanctionKind = .warning
    public var draftReason: String = ""
    public var draftAmount: Decimal?
    public var draftUnit: String = "MXN"
    public var draftEndsAt: Date?

    private let repository: CanonicalSanctionsRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalSanctionsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasSanctions: Bool { !sanctions.isEmpty }
    public var disputedCount: Int { sanctions.filter(\.isDisputed).count }
    public var activeCount: Int { sanctions.count }

    public var canSaveDraft: Bool {
        guard draftTargetMembershipId != nil else { return false }
        let trimmedReason = draftReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReason.isEmpty { return false }
        if draftKind.requiresAmount {
            guard let amount = draftAmount, amount > 0 else { return false }
            let trimmedUnit = draftUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUnit.isEmpty { return false }
        }
        return true
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if sanctions.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeSanctions(groupId: groupId)
            sanctions = fetched
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
        if loadedGroupId == groupId, !sanctions.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginIssuing(defaultTarget: UUID? = nil) {
        draftTargetMembershipId = defaultTarget
        draftKind = .warning
        draftReason = ""
        draftAmount = nil
        draftUnit = "MXN"
        draftEndsAt = nil
        errorMessage = nil
        isIssuePresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        guard let target = draftTargetMembershipId else {
            errorMessage = "Selecciona a quién aplica."
            return false
        }
        let trimmedReason = draftReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReason.isEmpty {
            errorMessage = "Escribe una razón."
            return false
        }
        if draftKind.requiresAmount {
            guard let amount = draftAmount, amount > 0 else {
                errorMessage = "Monto > 0 y moneda requeridos para monetaria."
                return false
            }
            let trimmedUnit = draftUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUnit.isEmpty {
                errorMessage = "Monto > 0 y moneda requeridos para monetaria."
                return false
            }
        }
        do {
            // D24P10B: rutea via governance. Backend resolver decide direct vs decision
            // (sanctions monetarias > threshold abren decisión per doctrine).
            let outcome = try await repository.issueSanctionViaGovernance(
                groupId: groupId,
                targetMembershipId: target,
                kind: draftKind,
                reason: trimmedReason,
                amount: draftKind.requiresAmount ? draftAmount : nil,
                unit: draftKind.requiresAmount ? draftUnit : nil,
                endsAt: draftEndsAt,
                clientId: UUID().uuidString
            )
            lastGovernanceOutcome = outcome
            switch outcome {
            case .directAllowed:
                await refresh(groupId: groupId)
                isIssuePresented = false
                errorMessage = nil
                return true
            case .decisionOpened:
                isIssuePresented = false
                errorMessage = nil
                return true
            case .denied(let reason, let missingPermission):
                errorMessage = missingPermission.map { "Falta permiso: \($0)" } ?? reason
                return false
            case .unsupported(let reason, _):
                errorMessage = "Acción no soportada (\(reason))"
                return false
            case .failed(let reason, let message):
                errorMessage = message ?? reason
                return false
            }
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftTargetMembershipId = nil
        draftKind = .warning
        draftReason = ""
        draftAmount = nil
        draftUnit = "MXN"
        draftEndsAt = nil
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
