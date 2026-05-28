import Foundation

/// Primitiva 17 (Roles / Permissions). Mirrors `public.group_roles` rows
/// returned by `list_group_roles(...)`, with the joined permission keys
/// and member count flattened so the list/edit UI doesn't need a second
/// hop.
///
/// System roles (founder / admin / member) are not editable from the
/// `update_role_permissions(...)` RPC — backend raises. Custom roles
/// can be created via `create_custom_role(...)`. Default role
/// (is_default=true) is assigned automatically when a member joins.
public struct GroupRole: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                       // role_id
    public let groupId: UUID
    public let key: String
    public let name: String
    public let description: String?
    public let isSystem: Bool
    public let isDefault: Bool
    public let permissionKeys: [String]
    public let memberCount: Int
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id              = "role_id"
        case groupId         = "group_id"
        case key
        case name
        case description
        case isSystem        = "is_system"
        case isDefault       = "is_default"
        case permissionKeys  = "permission_keys"
        case memberCount     = "member_count"
        case createdAt       = "created_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        key: String,
        name: String,
        description: String? = nil,
        isSystem: Bool = false,
        isDefault: Bool = false,
        permissionKeys: [String] = [],
        memberCount: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.key = key
        self.name = name
        self.description = description
        self.isSystem = isSystem
        self.isDefault = isDefault
        self.permissionKeys = permissionKeys
        self.memberCount = memberCount
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.key = try c.decode(String.self, forKey: .key)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.isSystem = try c.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.permissionKeys = try c.decodeIfPresent([String].self, forKey: .permissionKeys) ?? []
        self.memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension GroupRole {
    /// `true` when the role's permission set can be patched (custom
    /// non-system rows only).
    var isEditable: Bool { !isSystem }
    /// Membership count formatted for compact rows. Returns `nil` when
    /// zero so callers can hide the chip entirely.
    var memberCountLabel: String? {
        guard memberCount > 0 else { return nil }
        return memberCount == 1 ? "1 miembro" : "\(memberCount) miembros"
    }
}

// MARK: - Permissions catalog

/// Canonical category buckets for `public.permissions.category`. New
/// categories from a forward-compatible backend fall back to `.other`.
public enum PermissionCategory: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case group
    case members
    case roles
    case decisions
    case rules
    case sanctions
    case disputes
    case money
    case resources
    case culture
    case reputation
    case audit
    case other

    public var id: String { rawValue }

    /// Display order chosen to mirror how the founder thinks about
    /// governance (identity → power → process → boundary → memory).
    public static let displayOrder: [PermissionCategory] = [
        .group, .members, .roles,
        .decisions, .rules, .sanctions, .disputes,
        .money, .resources,
        .culture, .reputation, .audit, .other
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .group:      return L10n.Roles.categoryGroup
        case .members:    return L10n.Roles.categoryMembers
        case .roles:      return L10n.Roles.categoryRoles
        case .decisions:  return L10n.Roles.categoryDecisions
        case .rules:      return L10n.Roles.categoryRules
        case .sanctions:  return L10n.Roles.categorySanctions
        case .disputes:   return L10n.Roles.categoryDisputes
        case .money:      return L10n.Roles.categoryMoney
        case .resources:  return L10n.Roles.categoryResources
        case .culture:    return L10n.Roles.categoryCulture
        case .reputation: return L10n.Roles.categoryReputation
        case .audit:      return L10n.Roles.categoryAudit
        case .other:      return L10n.Roles.categoryOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .group:      return "person.3"
        case .members:    return "person.crop.rectangle.stack"
        case .roles:      return "person.crop.rectangle.badge.checkmark"
        case .decisions:  return "checkmark.seal"
        case .rules:      return "list.bullet.rectangle"
        case .sanctions:  return "exclamationmark.shield"
        case .disputes:   return "hand.raised"
        case .money:      return "banknote"
        case .resources:  return "square.stack.3d.up"
        case .culture:    return "heart"
        case .reputation: return "star.bubble"
        case .audit:      return "clock.arrow.circlepath"
        case .other:      return "ellipsis.circle"
        }
    }
}

/// One row of the static `public.permissions` table returned by
/// `list_permissions_catalog()`.
public struct PermissionCatalogEntry: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let key: String
    public let description: String
    public let category: PermissionCategory

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case description
        case category
    }

    public init(key: String, description: String, category: PermissionCategory) {
        self.key = key
        self.description = description
        self.category = category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.description = try c.decode(String.self, forKey: .description)
        let rawCategory = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        self.category = PermissionCategory(rawValue: rawCategory) ?? .other
    }
}
