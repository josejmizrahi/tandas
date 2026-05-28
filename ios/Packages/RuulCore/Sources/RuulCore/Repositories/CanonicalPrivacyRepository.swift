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
}
