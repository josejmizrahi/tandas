import Foundation

/// Foundation-scope repository for B7 (Privacy). Wraps
/// `group_visibility(...)` and `set_group_visibility(...)`. Backend
/// enforces the enum (`private` / `unlisted` / `public`) so iOS can
/// trust the returned string to map back through `GroupVisibility`.
public struct CanonicalPrivacyRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func visibility(groupId: UUID) async throws -> GroupVisibility {
        let raw = try await rpc.groupVisibility(groupId: groupId)
        return GroupVisibility(rawValue: raw) ?? .private
    }

    public func setVisibility(groupId: UUID, visibility: GroupVisibility) async throws -> GroupVisibility {
        let raw = try await rpc.setGroupVisibility(
            SetGroupVisibilityInput(groupId: groupId, visibility: visibility.rawValue)
        )
        return GroupVisibility(rawValue: raw) ?? visibility
    }

    /// D.22 — governance-aware visibility set. CONSTITUTIONAL → always
    /// opens a decision unless catalog is downgraded.
    public func setVisibilityViaGovernance(
        groupId: UUID,
        visibility: GroupVisibility
    ) async throws -> ActionOutcome {
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "group.visibility.set",
                targetKind: "group",
                targetId:   groupId,
                payload:    ["visibility": .string(visibility.rawValue)]
            )
        )
        if case .directAllowed = outcome {
            _ = try await rpc.setGroupVisibility(
                SetGroupVisibilityInput(groupId: groupId, visibility: visibility.rawValue)
            )
        }
        return outcome
    }
}
