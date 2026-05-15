import Foundation
import Observation
import OSLog
import RuulCore

/// Drives `RulePresetsView`. Lists current `group_policies` and
/// applies presets via `GroupPolicyRepository.applyPreset`. V1 only edits
/// the rule.* family via preset; per-row custom overrides land in V2.
@Observable @MainActor
public final class GroupRulesCoordinator {
    public let group: Group
    private let actorUserId: UUID
    private let policyRepo: any GroupPolicyRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group-rules")

    public private(set) var policies: [GroupPolicy] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isSaving: Bool = false
    public private(set) var error: String?

    public init(
        group: Group,
        actorUserId: UUID,
        policyRepo: any GroupPolicyRepository
    ) {
        self.group = group
        self.actorUserId = actorUserId
        self.policyRepo = policyRepo
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            policies = try await policyRepo.list(groupId: group.id)
        } catch {
            log.warning("policies load failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar las reglas del grupo."
        }
    }

    public func applyPreset(_ preset: GroupPolicyPreset) async {
        isSaving = true
        defer { isSaving = false }
        error = nil
        do {
            try await policyRepo.applyPreset(preset, groupId: group.id)
            await refresh()
        } catch {
            log.warning("applyPreset failed: \(error.localizedDescription)")
            self.error = "No se pudo aplicar el preset. Probá de nuevo."
        }
    }

    public func clearError() { error = nil }

    /// Returns the preset that exactly matches the current rule.* policies
    /// at scope=group, or nil if the state is custom (no full match). Used
    /// to highlight the active preset in the picker.
    public var activePreset: GroupPolicyPreset? {
        for preset in GroupPolicyPreset.all {
            let matches = preset.specs.allSatisfy { spec in
                guard let policy = policies.first(where: {
                    $0.targetAction == spec.action && $0.targetScope == "group"
                }) else { return false }
                return policy.policyType == spec.policyType
            }
            if matches { return preset }
        }
        return nil
    }

    /// Returns the active policy row for a `(action, group-scope)` tuple,
    /// or nil if none is seeded. The Q&A renderer uses this to translate
    /// the policy_type into a humanized answer (`humanAnswer(for:)`).
    public func policy(for action: TargetAction) -> GroupPolicy? {
        policies.first { $0.targetAction == action && $0.targetScope == "group" }
    }

    /// Human-readable answer for the active policy of a given action.
    /// Mapping:
    ///   direct         → "Cualquier miembro"
    ///   vote_required  → "Requiere votación (X% a favor)"
    ///   admin_only     → "Solo admins"
    ///   denied         → "No permitido"
    ///   (no row)       → "Sin configurar"
    /// Doctrine: never expose `policy_type` / `target_action` jargon — this
    /// is the only place we translate the table's raw values into a
    /// sentence the user can read aloud.
    public func humanAnswer(for action: TargetAction) -> String {
        guard let policy = policy(for: action) else { return "Sin configurar" }
        switch policy.policyType {
        case .direct:
            return "Cualquier miembro"
        case .voteRequired:
            let threshold = policy.approvalConfig?.thresholdPercent ?? 50
            return "Requiere votación (\(threshold)% a favor)"
        case .adminOnly:
            return "Solo admins"
        case .denied:
            return "No permitido"
        }
    }
}
