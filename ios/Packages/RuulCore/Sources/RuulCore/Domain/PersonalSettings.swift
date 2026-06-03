import Foundation

/// F.1A-1 — Configuración personal del actor autenticado.
/// Mirror del jsonb que devuelve `personal_settings_summary()`.
public struct PersonalSettings: Decodable, Sendable, Equatable {
    public let actorId: UUID
    public let profile: PersonalProfileSummary
    public let notifications: NotificationSettings
    public let privacy: PrivacySettings
    public let calendar: CalendarSettings
    public let contexts: ContextPreferences
    public let integrations: IntegrationsState
    public let availableActions: [String]

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case profile
        case notifications
        case privacy
        case calendar
        case contexts
        case integrations
        case availableActions = "available_actions"
    }

    public init(
        actorId: UUID,
        profile: PersonalProfileSummary,
        notifications: NotificationSettings,
        privacy: PrivacySettings,
        calendar: CalendarSettings,
        contexts: ContextPreferences,
        integrations: IntegrationsState,
        availableActions: [String]
    ) {
        self.actorId = actorId
        self.profile = profile
        self.notifications = notifications
        self.privacy = privacy
        self.calendar = calendar
        self.contexts = contexts
        self.integrations = integrations
        self.availableActions = availableActions
    }

    public func can(_ action: String) -> Bool { availableActions.contains(action) }
}

public struct PersonalProfileSummary: Decodable, Sendable, Equatable {
    public let fullName: String?
    public let preferredName: String?
    public let phone: String?
    public let email: String?
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case preferredName = "preferred_name"
        case phone
        case email
        case avatarUrl = "avatar_url"
    }

    public init(
        fullName: String? = nil,
        preferredName: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        avatarUrl: String? = nil
    ) {
        self.fullName = fullName
        self.preferredName = preferredName
        self.phone = phone
        self.email = email
        self.avatarUrl = avatarUrl
    }

    public var displayName: String { preferredName ?? fullName ?? "—" }
}

/// 7 categorías de notificaciones. Cada slot tiene push + email bool.
public struct NotificationSettings: Decodable, Sendable, Equatable {
    public let invitations: NotificationSlot
    public let decisions: NotificationSlot
    public let reservations: NotificationSlot
    public let events: NotificationSlot
    public let obligations: NotificationSlot
    public let money: NotificationSlot
    public let rules: NotificationSlot
}

public struct NotificationSlot: Decodable, Sendable, Equatable {
    public let push: Bool
    public let email: Bool

    public init(push: Bool = true, email: Bool = true) {
        self.push = push
        self.email = email
    }
}

public struct PrivacySettings: Decodable, Sendable, Equatable {
    public let discoverableBy: String
    public let whoCanInviteMe: String
    public let profileVisibility: String

    enum CodingKeys: String, CodingKey {
        case discoverableBy = "discoverable_by"
        case whoCanInviteMe = "who_can_invite_me"
        case profileVisibility = "profile_visibility"
    }
}

public struct CalendarSettings: Decodable, Sendable, Equatable {
    public let timeZone: String
    public let firstDayOfWeek: String

    enum CodingKeys: String, CodingKey {
        case timeZone = "time_zone"
        case firstDayOfWeek = "first_day_of_week"
    }
}

public struct ContextPreferences: Decodable, Sendable, Equatable {
    public let defaultContextActorId: UUID?
    public let lastContextActorId: UUID?

    enum CodingKeys: String, CodingKey {
        case defaultContextActorId = "default_context_actor_id"
        case lastContextActorId = "last_context_actor_id"
    }
}

public struct IntegrationsState: Decodable, Sendable, Equatable {
    public let googleCalendar: IntegrationStatus
    public let appleCalendar: IntegrationStatus
    public let wise: IntegrationStatus
    public let whatsapp: IntegrationStatus

    enum CodingKeys: String, CodingKey {
        case googleCalendar = "google_calendar"
        case appleCalendar = "apple_calendar"
        case wise
        case whatsapp
    }
}

public struct IntegrationStatus: Decodable, Sendable, Equatable {
    public let connected: Bool

    public init(connected: Bool = false) { self.connected = connected }
}
