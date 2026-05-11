import Foundation

/// Pre-baked governance configurations the founder picks from the
/// Group Rules settings screen. Each preset is a list of (action, policy)
/// specs that `GroupPolicyRepository.applyPreset` materializes into table
/// rows.
///
/// V1 ships three presets along a "trust spectrum":
/// - **Casual**: admin can change anything directly. No friction.
/// - **Balanced**: admin toggles + creates directly; cost-impacting changes
///   (amount edits, deletes) go to majority vote.
/// - **Strict**: nearly everything passes through vote, with supermajority
///   on destructive changes.
public struct GroupPolicyPreset: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let specs: [Spec]

    public struct Spec: Sendable, Hashable {
        public let action: TargetAction
        public let policyType: PolicyType
        public let approvalConfig: ApprovalConfig?

        public init(
            action: TargetAction,
            policyType: PolicyType,
            approvalConfig: ApprovalConfig? = nil
        ) {
            self.action = action
            self.policyType = policyType
            self.approvalConfig = approvalConfig
        }
    }

    public init(id: String, title: String, subtitle: String, specs: [Spec]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.specs = specs
    }

    /// Anyone with `Permission.modifyRules` (founder + custom admin roles)
    /// can edit rules directly. No votes.
    public static let casual = GroupPolicyPreset(
        id: "casual",
        title: "Relajado",
        subtitle: "Los admins pueden cambiar las reglas directo.",
        specs: TargetAction.allCases.map {
            Spec(action: $0, policyType: .adminOnly)
        }
    )

    /// Toggle + create are admin-direct; amount changes and deletes need a
    /// simple majority. Mid-stakes groups.
    public static let balanced = GroupPolicyPreset(
        id: "balanced",
        title: "Equilibrado",
        subtitle: "Cambios importantes los aprueba la mayoría.",
        specs: [
            .init(action: .ruleToggle,       policyType: .adminOnly),
            .init(action: .ruleCreate,       policyType: .adminOnly),
            .init(action: .ruleUpdateAmount, policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleDelete,       policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)),
        ]
    )

    /// Almost everything is vote-gated; destructive changes require a 2/3
    /// supermajority. High-stakes / formal groups.
    public static let strict = GroupPolicyPreset(
        id: "strict",
        title: "Estricto",
        subtitle: "Casi todos los cambios pasan por votación.",
        specs: [
            .init(action: .ruleToggle,       policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 60, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleCreate,       policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 60, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleUpdateAmount, policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 60, thresholdPercent: 66, durationHours: 96)),
            .init(action: .ruleDelete,       policyType: .voteRequired,
                  approvalConfig: .init(quorumPercent: 60, thresholdPercent: 66, durationHours: 96)),
        ]
    )

    public static let all: [GroupPolicyPreset] = [.casual, .balanced, .strict]
}
