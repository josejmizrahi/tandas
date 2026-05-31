import Foundation

/// Row-shaped projection of a `group_memberships` record joined with the
/// member's `profiles` data. Slice 6 introduces this as a presentation
/// type only — a real `CanonicalMembersRepository` lands in a follow-up
/// slice. Treat this as the contract every member-aware view consumes.
public struct MemberListItem: Identifiable, Equatable, Sendable, Hashable {
    public let id: UUID                 // membership id
    public let userId: UUID?            // null when the row is a placeholder/invite-only
    public let displayName: String
    public let avatarURL: URL?
    public let status: MembershipStatus
    public let membershipType: MembershipType
    public let roleNames: [String]
    public let joinedAt: Date?
    public let isCurrentUser: Bool

    public init(
        id: UUID,
        userId: UUID? = nil,
        displayName: String,
        avatarURL: URL? = nil,
        status: MembershipStatus = .active,
        membershipType: MembershipType = .member,
        roleNames: [String] = [],
        joinedAt: Date? = nil,
        isCurrentUser: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.status = status
        self.membershipType = membershipType
        self.roleNames = roleNames
        self.joinedAt = joinedAt
        self.isCurrentUser = isCurrentUser
    }
}

/// Mirrors the canonical `group_memberships.status` enum. Strings match
/// the dev backend values one-to-one so direct decoding from the future
/// repository will work without remapping.
public enum MembershipStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case requested
    case invited
    case active
    /// V3-D.20 — pausa voluntaria/temporal, no punitiva.
    case paused
    case suspended
    /// V3-D.20 — salida administrativa reversible (banned = irreversible).
    case removed
    case left
    case banned

    public var label: LocalizedStringResource {
        switch self {
        case .requested: return LocalizedStringResource("members.status.requested", defaultValue: "Solicitó")
        case .invited:   return LocalizedStringResource("members.status.invited",   defaultValue: "Invitado")
        case .active:    return LocalizedStringResource("members.status.active",    defaultValue: "Activo")
        case .paused:    return LocalizedStringResource("members.status.paused",    defaultValue: "En pausa")
        case .suspended: return LocalizedStringResource("members.status.suspended", defaultValue: "Suspendido")
        case .removed:   return LocalizedStringResource("members.status.removed",   defaultValue: "Removido")
        case .left:      return LocalizedStringResource("members.status.left",      defaultValue: "Se fue")
        case .banned:    return LocalizedStringResource("members.status.banned",    defaultValue: "Baneado")
        }
    }

    /// V3-D.20 — true cuando el estado impide actuar / votar en el grupo.
    public var isInactive: Bool {
        switch self {
        case .active: return false
        case .requested, .invited, .paused, .suspended, .removed, .left, .banned: return true
        }
    }

    /// V3-D.20 — true cuando la reactivación requiere una decisión explícita.
    public var requiresDecisionToReinstate: Bool { self == .banned }
}

/// Mirrors the canonical `group_memberships.membership_type` enum.
public enum MembershipType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case member
    case provisional
    case guest
    case observer
    case external

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .member:      return LocalizedStringResource("members.type.member",      defaultValue: "Miembro")
        case .provisional: return LocalizedStringResource("members.type.provisional", defaultValue: "Provisional")
        case .guest:       return LocalizedStringResource("members.type.guest",       defaultValue: "Invitado")
        case .observer:    return LocalizedStringResource("members.type.observer",    defaultValue: "Observador")
        case .external:    return LocalizedStringResource("members.type.external",    defaultValue: "Externo")
        }
    }

    /// Subset the invite form lets a user pick. `external` is reserved
    /// for backend-driven flows (e.g. claim links from outside the
    /// group) and intentionally not surfaced as a user-selectable type.
    public static var invitableCases: [MembershipType] {
        [.member, .provisional, .guest, .observer]
    }
}

// MARK: - Presentation helpers

public extension MemberListItem {
    /// Two-letter monogram for the avatar fallback ("Ana López" → "AL").
    /// Falls back to "?" when the display name is empty.
    var initials: String {
        let parts = displayName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "?" }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    /// Optional subtitle for the row — currently just the first role
    /// with a "+N" suffix when there are extras. Returns nil when the
    /// member has no roles assigned so the row can collapse to a single
    /// line.
    var subtitle: String? {
        guard let first = roleNames.first else { return nil }
        if roleNames.count > 1 {
            return "\(first) · +\(roleNames.count - 1)"
        }
        return first
    }

    /// VoiceOver-friendly composite label.
    var accessibilityLabelText: String {
        var parts: [String] = [displayName]
        if !roleNames.isEmpty {
            parts.append(roleNames.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }
}
