import Foundation

/// Definition of a role within a group. Stored as a value in
/// `groups.roles` jsonb (mig 00063); `id` is the jsonb key. System
/// roles (`founder`, `member`) ship with every group; custom roles
/// (`treasurer`, `seat_owner`, etc.) come from
/// `templates.config.defaultRoles` or — Phase 5+ — from founder edits
/// via `GroupRolesSheet`.
public struct RoleDefinition: Sendable, Hashable, Codable, Identifiable {
    /// jsonb key — the role's stable identifier. Typically lowercase
    /// snake_case (`treasurer`, `seat_owner`). Cross-template stable.
    public let id: String

    /// Display label for the role. Optional for system roles (which
    /// have hardcoded localized strings via `MemberRole`); required
    /// for custom roles so the UI can render something meaningful.
    public let label: String?

    /// Permissions this role grants. Order is informational only;
    /// `has_permission()` checks membership. Sendable Set isn't a
    /// stable Codable shape, so this is `[Permission]` plus a
    /// computed `permissionSet` helper.
    public let permissions: [Permission]

    /// Maximum number of group members that may simultaneously hold
    /// this role. nil = unlimited. Enforced by `assign_role` RPC
    /// (Phase 5).
    public let maxHolders: Int?

    /// True for the two roles every group ships with (`founder`,
    /// `member`). System roles cannot be deleted by founders.
    public let system: Bool

    public init(
        id: String,
        label: String? = nil,
        permissions: [Permission] = [],
        maxHolders: Int? = nil,
        system: Bool = false
    ) {
        self.id = id
        self.label = label
        self.permissions = permissions
        self.maxHolders = maxHolders
        self.system = system
    }

    /// O(1) permission membership lookup. Backed by Set since jsonb
    /// arrays are typically tiny (<10 entries) — Set construction
    /// per-call is cheap.
    public var permissionSet: Set<Permission> {
        Set(permissions)
    }

    public func grants(_ permission: Permission) -> Bool {
        permissions.contains(permission)
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case label
        case permissions
        case maxHolders = "max_holders"
        case system
    }

    /// V1 system-roles baseline mirroring the seed in mig 00063.
    /// Used as the offline / pre-migration fallback when
    /// `Group.roles` decodes to nil.
    public static let v1SystemRoles: [String: RoleDefinition] = [
        "founder": RoleDefinition(
            id: "founder",
            permissions: [
                .modifyGovernance, .modifyRules, .modifyMembers,
                .assignRoles, .removeMember, .voidFine,
                .closeAppeal, .createVotes
            ],
            system: true
        ),
        "member": RoleDefinition(
            id: "member",
            permissions: [.createVotes, .castVote],
            system: true
        )
    ]

    /// Codable from the jsonb VALUE shape (`{ system, label?,
    /// permissions, max_holders? }`). The KEY (= id) lives outside
    /// the value so callers must supply it externally — see
    /// `Group.decodeRoles(from:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Server doesn't store id inside the value; consumers patch
        // it after decode. Fall back to "" so single-value decoding
        // still produces a valid struct that the caller can rewrite.
        self.id           = (try? c.decode(String.self, forKey: .id)) ?? ""
        self.label        = try? c.decodeIfPresent(String.self, forKey: .label)
        self.permissions  = (try? c.decode([Permission].self, forKey: .permissions)) ?? []
        self.maxHolders   = try? c.decodeIfPresent(Int.self, forKey: .maxHolders)
        self.system       = (try? c.decode(Bool.self, forKey: .system)) ?? false
    }
}
