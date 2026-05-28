import Foundation

/// B7 — Notifications. Caller-owned per-group preferences (one row per
/// category × channel). Backend column `notification_preferences.category`
/// is free-text; iOS curates the canonical set here so the UI renders a
/// stable grid regardless of which categories the cron emits.
public enum NotificationCategory: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case decisions
    case sanctions
    case disputes
    case money
    case members

    public var id: String { rawValue }

    /// Display order in the settings grid.
    public static let displayOrder: [NotificationCategory] = [
        .decisions, .sanctions, .disputes, .money, .members
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .decisions: return L10n.NotificationSettings.categoryDecisions
        case .sanctions: return L10n.NotificationSettings.categorySanctions
        case .disputes:  return L10n.NotificationSettings.categoryDisputes
        case .money:     return L10n.NotificationSettings.categoryMoney
        case .members:   return L10n.NotificationSettings.categoryMembers
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .decisions: return L10n.NotificationSettings.categoryDecisionsSubtitle
        case .sanctions: return L10n.NotificationSettings.categorySanctionsSubtitle
        case .disputes:  return L10n.NotificationSettings.categoryDisputesSubtitle
        case .money:     return L10n.NotificationSettings.categoryMoneySubtitle
        case .members:   return L10n.NotificationSettings.categoryMembersSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .decisions: return "checkmark.seal"
        case .sanctions: return "exclamationmark.shield"
        case .disputes:  return "hand.raised"
        case .money:     return "banknote"
        case .members:   return "person.3"
        }
    }
}

/// Backend `notification_preferences.channel` CHECK accepts
/// push / email / sms / in_app. Foundation V1 only renders push +
/// in_app (email + sms infra not wired yet).
public enum NotificationChannel: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case push
    case email
    case sms
    case inApp = "in_app"

    public var id: String { rawValue }

    /// Channels iOS shows in the toggle grid.
    public static let userSelectable: [NotificationChannel] = [.push, .inApp]

    public var label: LocalizedStringResource {
        switch self {
        case .push:  return L10n.NotificationSettings.channelPush
        case .email: return L10n.NotificationSettings.channelEmail
        case .sms:   return L10n.NotificationSettings.channelSMS
        case .inApp: return L10n.NotificationSettings.channelInApp
        }
    }

    public var systemImageName: String {
        switch self {
        case .push:  return "bell.badge"
        case .email: return "envelope"
        case .sms:   return "text.bubble"
        case .inApp: return "app.badge"
        }
    }
}

/// One stored preference row. Wire shape mirrors
/// `my_notification_preferences(...)` exactly.
public struct NotificationPreferenceRow: Codable, Equatable, Sendable, Hashable {
    public let groupId: UUID
    public let category: String
    public let channel: String
    public let enabled: Bool
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case groupId   = "group_id"
        case category
        case channel
        case enabled
        case updatedAt = "updated_at"
    }

    public init(
        groupId: UUID,
        category: String,
        channel: String,
        enabled: Bool,
        updatedAt: Date? = nil
    ) {
        self.groupId = groupId
        self.category = category
        self.channel = channel
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// Composite key used by the iOS store to look up overrides.
    public var lookupKey: String { "\(category):\(channel)" }

    public static func lookupKey(category: NotificationCategory, channel: NotificationChannel) -> String {
        "\(category.rawValue):\(channel.rawValue)"
    }
}

/// B7 — Privacy. Mirrors `groups.visibility` CHECK constraint.
public enum GroupVisibility: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case `private`
    case unlisted
    case `public`

    public var id: String { rawValue }

    public static let displayOrder: [GroupVisibility] = [.private, .unlisted, .public]

    public var label: LocalizedStringResource {
        switch self {
        case .private:  return L10n.Privacy.visibilityPrivate
        case .unlisted: return L10n.Privacy.visibilityUnlisted
        case .public:   return L10n.Privacy.visibilityPublic
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .private:  return L10n.Privacy.visibilityPrivateSubtitle
        case .unlisted: return L10n.Privacy.visibilityUnlistedSubtitle
        case .public:   return L10n.Privacy.visibilityPublicSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .private:  return "lock"
        case .unlisted: return "eye.slash"
        case .public:   return "globe"
        }
    }
}
