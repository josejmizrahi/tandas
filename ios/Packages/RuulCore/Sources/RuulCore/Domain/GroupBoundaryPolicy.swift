import Foundation

/// Primitiva 2 (Boundary). Mirrors the jsonb returned by
/// `group_boundary_policy(...)` / `set_group_boundary_policy(...)`.
/// Persisted under `groups.settings.boundary_policy`; defaults are
/// baked in when the bag is empty so the read RPC never returns nil
/// fields.
public enum BoundaryEntryMode: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case open
    case inviteOnly = "invite_only"
    case closed

    public var id: String { rawValue }

    public static let displayOrder: [BoundaryEntryMode] = [.open, .inviteOnly, .closed]

    public var label: LocalizedStringResource {
        switch self {
        case .open:       return L10n.BoundaryPolicy.entryOpen
        case .inviteOnly: return L10n.BoundaryPolicy.entryInviteOnly
        case .closed:     return L10n.BoundaryPolicy.entryClosed
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .open:       return L10n.BoundaryPolicy.entryOpenSubtitle
        case .inviteOnly: return L10n.BoundaryPolicy.entryInviteOnlySubtitle
        case .closed:     return L10n.BoundaryPolicy.entryClosedSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .open:       return "door.left.hand.open"
        case .inviteOnly: return "envelope"
        case .closed:     return "lock"
        }
    }
}

public enum BoundaryInviterScope: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case anyMember   = "any_member"
    case adminsOnly  = "admins_only"

    public var id: String { rawValue }

    public static let displayOrder: [BoundaryInviterScope] = [.anyMember, .adminsOnly]

    public var label: LocalizedStringResource {
        switch self {
        case .anyMember:  return L10n.BoundaryPolicy.inviterAnyMember
        case .adminsOnly: return L10n.BoundaryPolicy.inviterAdminsOnly
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .anyMember:  return L10n.BoundaryPolicy.inviterAnyMemberSubtitle
        case .adminsOnly: return L10n.BoundaryPolicy.inviterAdminsOnlySubtitle
        }
    }
}

public enum BoundaryExitMode: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case free
    case requiresNotice = "requires_notice"

    public var id: String { rawValue }

    public static let displayOrder: [BoundaryExitMode] = [.free, .requiresNotice]

    public var label: LocalizedStringResource {
        switch self {
        case .free:           return L10n.BoundaryPolicy.exitFree
        case .requiresNotice: return L10n.BoundaryPolicy.exitRequiresNotice
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .free:           return L10n.BoundaryPolicy.exitFreeSubtitle
        case .requiresNotice: return L10n.BoundaryPolicy.exitRequiresNoticeSubtitle
        }
    }
}

public struct GroupBoundaryPolicy: Codable, Equatable, Sendable, Hashable {
    public let groupId: UUID
    public let entryMode: BoundaryEntryMode
    public let whoCanInvite: BoundaryInviterScope
    public let requiresApproval: Bool
    public let exitMode: BoundaryExitMode
    public let notes: String?
    /// `true` when groups.settings.boundary_policy is empty — Foundation
    /// surfaces this so the Edit sheet can distinguish "first time" vs
    /// "edit".
    public let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case groupId           = "group_id"
        case entryMode         = "entry_mode"
        case whoCanInvite      = "who_can_invite"
        case requiresApproval  = "requires_approval"
        case exitMode          = "exit_mode"
        case notes
        case isDefault         = "is_default"
    }

    public init(
        groupId: UUID,
        entryMode: BoundaryEntryMode = .inviteOnly,
        whoCanInvite: BoundaryInviterScope = .anyMember,
        requiresApproval: Bool = false,
        exitMode: BoundaryExitMode = .free,
        notes: String? = nil,
        isDefault: Bool = true
    ) {
        self.groupId = groupId
        self.entryMode = entryMode
        self.whoCanInvite = whoCanInvite
        self.requiresApproval = requiresApproval
        self.exitMode = exitMode
        self.notes = notes
        self.isDefault = isDefault
    }

    /// Tolerant decode: unknown enum values fall back to safe defaults
    /// so a forward-compatible backend never crashes the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawEntry = try c.decodeIfPresent(String.self, forKey: .entryMode) ?? "invite_only"
        self.entryMode = BoundaryEntryMode(rawValue: rawEntry) ?? .inviteOnly
        let rawInviter = try c.decodeIfPresent(String.self, forKey: .whoCanInvite) ?? "any_member"
        self.whoCanInvite = BoundaryInviterScope(rawValue: rawInviter) ?? .anyMember
        self.requiresApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
        let rawExit = try c.decodeIfPresent(String.self, forKey: .exitMode) ?? "free"
        self.exitMode = BoundaryExitMode(rawValue: rawExit) ?? .free
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true
    }
}

public extension GroupBoundaryPolicy {
    var trimmedNotes: String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
