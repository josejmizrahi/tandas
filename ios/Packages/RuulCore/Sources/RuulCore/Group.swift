import Foundation

/// Bare community per OpenPlatform Taxonomy §0. Group is identity +
/// membership + governance + module catalog. All vertical/scheduling state
/// lives on Resources (Taxonomy §1) and CapabilityBlocks (Taxonomy §2).
///
/// Post BigBang (mig 00078) the schema is reduced to the columns below.
/// All recurring-dinner / fines / fund / voting flat fields are gone —
/// they live as: capability blocks on resources, module config, governance
/// jsonb, or atoms in ledger_entries.
public struct Group: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let currency: String
    public let timezone: String?
    public let inviteCode: String
    public let coverImageName: String?
    public let createdBy: UUID
    public let createdAt: Date
    public let updatedAt: Date?
    /// Soft-delete timestamp (mig 00177). Non-nil = archived. Hidden from
    /// default lists; only the original founder can see / restore.
    public let archivedAt: Date?

    /// Template id this group was created from. Optional — bare groups
    /// (no preset) are valid.
    public let baseTemplate: String?
    /// Module ids active in this group. Drives capability resolution.
    public let activeModules: [String]?
    /// Per-group governance configuration (quorum, thresholds, permissions).
    public let governance: GovernanceRules?
    /// Per-group settings jsonb. Currently holds eventVocabulary
    /// (display copy for "event" surfaces).
    public let settings: GroupSettings?
    /// Role catalog. id → RoleDefinition. Always contains system roles
    /// (`founder`, `member`); custom roles come from templates or
    /// founder edits.
    public let roles: [String: RoleDefinition]?

    // MARK: - DS v3 multi-group avatar fields (mig 00036)

    public let category: GroupCategory
    public let initials: String
    public let avatarUrl: String?

    public enum CodingKeys: String, CodingKey {
        case id, name, description, currency, timezone
        case governance, settings, category, initials, roles
        case inviteCode      = "invite_code"
        case coverImageName  = "cover_image_name"
        case baseTemplate    = "base_template"
        case activeModules   = "active_modules"
        case createdBy       = "created_by"
        case createdAt       = "created_at"
        case updatedAt       = "updated_at"
        case avatarUrl       = "avatar_url"
        case archivedAt      = "archived_at"
    }

    public init(
        id: UUID,
        name: String,
        description: String? = nil,
        currency: String = "MXN",
        timezone: String? = nil,
        inviteCode: String,
        coverImageName: String? = nil,
        baseTemplate: String? = nil,
        activeModules: [String]? = nil,
        governance: GovernanceRules? = nil,
        settings: GroupSettings? = nil,
        roles: [String: RoleDefinition]? = nil,
        category: GroupCategory = .socialRecurring,
        initials: String = "",
        avatarUrl: String? = nil,
        createdBy: UUID,
        createdAt: Date,
        updatedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.currency = currency
        self.timezone = timezone
        self.inviteCode = inviteCode
        self.coverImageName = coverImageName
        self.baseTemplate = baseTemplate
        self.activeModules = activeModules
        self.governance = governance
        self.settings = settings
        self.roles = roles
        self.category = category
        self.initials = initials.isEmpty ? Self.derivedInitials(from: name) : initials
        self.avatarUrl = avatarUrl
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.name            = try c.decode(String.self, forKey: .name)
        self.description     = try c.decodeIfPresent(String.self, forKey: .description)
        self.currency        = (try? c.decode(String.self, forKey: .currency)) ?? "MXN"
        self.timezone        = try c.decodeIfPresent(String.self, forKey: .timezone)
        self.inviteCode      = try c.decode(String.self, forKey: .inviteCode)
        self.coverImageName  = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.baseTemplate    = try c.decodeIfPresent(String.self, forKey: .baseTemplate)
        self.activeModules   = try c.decodeIfPresent([String].self, forKey: .activeModules)
        self.governance      = try c.decodeIfPresent(GovernanceRules.self, forKey: .governance)
        self.settings        = try c.decodeIfPresent(GroupSettings.self,  forKey: .settings)

        if let raw = try? c.decodeIfPresent([String: RoleDefinition].self, forKey: .roles) {
            self.roles = raw.reduce(into: [String: RoleDefinition]()) { acc, kv in
                let (key, def) = kv
                acc[key] = RoleDefinition(
                    id: key,
                    label: def.label,
                    permissions: def.permissions,
                    maxHolders: def.maxHolders,
                    system: def.system
                )
            }
        } else {
            self.roles = nil
        }

        self.category        = (try? c.decode(GroupCategory.self, forKey: .category)) ?? .socialRecurring
        let decodedInitials  = try c.decodeIfPresent(String.self, forKey: .initials) ?? ""
        let nameForInitials  = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.initials        = decodedInitials.isEmpty ? Self.derivedInitials(from: nameForInitials) : decodedInitials
        self.avatarUrl       = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.createdBy       = try c.decode(UUID.self, forKey: .createdBy)
        self.createdAt       = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt       = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.archivedAt      = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    // MARK: - Derived

    /// User-facing word for "event" in this group ("Cena", "Brunch", etc.).
    /// Lives in settings.eventVocabulary jsonb. Defaults to a neutral
    /// "evento" when absent.
    public var eventVocabulary: String {
        settings?.eventVocabulary ?? "evento"
    }

    /// Returns a copy with `inviteCode` replaced. Used by `GroupInfoSheet`
    /// after `regenerate_invite_code` (mig 00176) so the UI reflects the
    /// rotation without waiting for an `AppState.listMine()` refetch.
    public func withInviteCode(_ newCode: String) -> Group {
        Group(
            id: id,
            name: name,
            description: description,
            currency: currency,
            timezone: timezone,
            inviteCode: newCode,
            coverImageName: coverImageName,
            baseTemplate: baseTemplate,
            activeModules: activeModules,
            governance: governance,
            settings: settings,
            roles: roles,
            category: category,
            initials: initials,
            avatarUrl: avatarUrl,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }

    /// True when `archived_at` is set. UI hides such groups from active lists.
    public var isArchived: Bool { archivedAt != nil }

    /// Returns the effective governance for this group: stored rules or
    /// recurring-dinner defaults.
    public var effectiveGovernance: GovernanceRules {
        governance ?? .recurringDinnerDefaults
    }

    /// Active module ids — empty when the group is bare (no modules opted in).
    public var effectiveActiveModules: [String] {
        activeModules ?? []
    }

    /// Returns the base template id, or empty string if the group was
    /// created bare (no preset). Useful for UI gates that want a non-nil
    /// string to compare.
    public var effectiveBaseTemplate: String {
        baseTemplate ?? ""
    }

    /// Returns the effective role catalog: server-provided when present,
    /// otherwise the V1 system-roles baseline.
    public var effectiveRoles: [String: RoleDefinition] {
        roles ?? RoleDefinition.v1SystemRoles
    }

    public func roleDefinition(for roleId: String) -> RoleDefinition? {
        let normalized = roleId == "admin" ? "founder" : roleId
        return effectiveRoles[normalized]
    }

    public var avatarURL: URL? {
        avatarUrl.flatMap(URL.init(string:))
    }

    public static func derivedInitials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "?" }
        if words.count >= 2 {
            let first  = words[0].first.map(String.init) ?? ""
            let second = words[1].first.map(String.init) ?? ""
            return (first + second).uppercased()
        } else {
            return String(trimmed.prefix(2)).uppercased()
        }
    }
}

public struct GroupDetail: Codable, Sendable {
    public let group: Group
    public let memberCount: Int
    public let myRole: String  // founder | member | admin (alias)
    /// Verbatim `group_members.roles` jsonb array for the calling user.
    /// Empty for legacy paths that don't fetch it. Populated by
    /// `LiveGroupsRepository.get` so Phase 5 permission-gated UI can
    /// resolve against the role catalog without a second fetch.
    public let myRawRoles: [String]

    public init(group: Group, memberCount: Int, myRole: String, myRawRoles: [String] = []) {
        self.group = group
        self.memberCount = memberCount
        self.myRole = myRole
        self.myRawRoles = myRawRoles
    }
}

/// Parameters for creating a new bare group.
/// Per OpenPlatform: a group starts with no resources, no recurrence, no
/// modules unless the founder picks a preset that supplies them.
/// Recurring-dinner-specific params (defaultDayOfWeek/StartTime/Location)
/// are gone — those live on a ResourceSeries when the founder creates one.
public struct CreateGroupParams: Sendable {
    public let name: String
    public let description: String?
    public let currency: String
    public let timezone: String?
    public let baseTemplate: String?
    public let coverImageName: String?
    public let initialEventVocabulary: String?

    public init(
        name: String,
        description: String? = nil,
        currency: String = "MXN",
        timezone: String? = nil,
        baseTemplate: String? = nil,
        coverImageName: String? = nil,
        initialEventVocabulary: String? = nil
    ) {
        self.name = name
        self.description = description
        self.currency = currency
        self.timezone = timezone
        self.baseTemplate = baseTemplate
        self.coverImageName = coverImageName
        self.initialEventVocabulary = initialEventVocabulary
    }
}
