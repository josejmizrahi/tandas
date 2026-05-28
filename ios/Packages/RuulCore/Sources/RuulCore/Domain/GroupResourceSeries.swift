import Foundation

/// Primitiva 21 (Ritual). Mirrors `public.group_resource_series` via
/// `list_group_resource_series(...)`. A series is a recurrence; iOS
/// only surfaces those flagged as rituals (ritual_meaning OR
/// ritual_marker_kind set) — generic recurrences without ritual
/// annotation stay invisible until a recurrence-of-things surface
/// lands.
///
/// Backend CHECK constraints (mig 00001):
/// - `cadence` ∈ once / daily / weekly / biweekly / monthly /
///   quarterly / yearly / custom
/// - `ritual_marker_kind` ∈ weekly_meeting / monthly_meeting /
///   annual_assembly / onboarding / farewell / celebration /
///   retrospective / none

public enum RitualCadence: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case once
    case daily
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly
    case custom

    public var id: String { rawValue }

    /// Canonical display order from "rare" to "frequent" — Apple's
    /// Calendar uses this ordering in recurrence editors.
    public static let displayOrder: [RitualCadence] = [
        .once, .daily, .weekly, .biweekly, .monthly, .quarterly, .yearly, .custom
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .once:      return L10n.Rituals.cadenceOnce
        case .daily:     return L10n.Rituals.cadenceDaily
        case .weekly:    return L10n.Rituals.cadenceWeekly
        case .biweekly:  return L10n.Rituals.cadenceBiweekly
        case .monthly:   return L10n.Rituals.cadenceMonthly
        case .quarterly: return L10n.Rituals.cadenceQuarterly
        case .yearly:    return L10n.Rituals.cadenceYearly
        case .custom:    return L10n.Rituals.cadenceCustom
        }
    }
}

public enum RitualMarkerKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case weeklyMeeting   = "weekly_meeting"
    case monthlyMeeting  = "monthly_meeting"
    case annualAssembly  = "annual_assembly"
    case onboarding
    case farewell
    case celebration
    case retrospective
    case none

    public var id: String { rawValue }

    public static let selectable: [RitualMarkerKind] = [
        .weeklyMeeting, .monthlyMeeting, .annualAssembly,
        .onboarding, .farewell, .celebration, .retrospective
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .weeklyMeeting:   return L10n.Rituals.markerWeeklyMeeting
        case .monthlyMeeting:  return L10n.Rituals.markerMonthlyMeeting
        case .annualAssembly:  return L10n.Rituals.markerAnnualAssembly
        case .onboarding:      return L10n.Rituals.markerOnboarding
        case .farewell:        return L10n.Rituals.markerFarewell
        case .celebration:     return L10n.Rituals.markerCelebration
        case .retrospective:   return L10n.Rituals.markerRetrospective
        case .none:            return L10n.Rituals.markerNone
        }
    }

    public var systemImageName: String {
        switch self {
        case .weeklyMeeting:   return "calendar.day.timeline.left"
        case .monthlyMeeting:  return "calendar"
        case .annualAssembly:  return "star.circle"
        case .onboarding:      return "person.fill.badge.plus"
        case .farewell:        return "hand.wave"
        case .celebration:     return "party.popper"
        case .retrospective:   return "arrow.uturn.backward"
        case .none:            return "circle"
        }
    }
}

public struct GroupResourceSeries: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceType: String
    public let cadence: RitualCadence
    public let startsOn: Date?
    public let endsOn: Date?
    public let ritualMeaning: String?
    public let ritualMarkerKind: RitualMarkerKind?
    public let createdBy: UUID?
    public let createdByDisplayName: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                    = "series_id"
        case groupId               = "group_id"
        case resourceType          = "resource_type"
        case cadence
        case startsOn              = "starts_on"
        case endsOn                = "ends_on"
        case ritualMeaning         = "ritual_meaning"
        case ritualMarkerKind      = "ritual_marker_kind"
        case createdBy             = "created_by"
        case createdByDisplayName  = "created_by_display_name"
        case createdAt             = "created_at"
        case updatedAt             = "updated_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        resourceType: String = "event",
        cadence: RitualCadence = .monthly,
        startsOn: Date? = nil,
        endsOn: Date? = nil,
        ritualMeaning: String? = nil,
        ritualMarkerKind: RitualMarkerKind? = nil,
        createdBy: UUID? = nil,
        createdByDisplayName: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.cadence = cadence
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.ritualMeaning = ritualMeaning
        self.ritualMarkerKind = ritualMarkerKind
        self.createdBy = createdBy
        self.createdByDisplayName = createdByDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decode: backend date columns arrive as ISO strings
    /// `YYYY-MM-DD`, which JSONDecoder's default strategy parses as
    /// `Date` only with `.iso8601` set. Unknown enum values fall back
    /// to safe defaults so a forward-compatible backend never crashes
    /// the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.resourceType = try c.decodeIfPresent(String.self, forKey: .resourceType) ?? "event"
        let rawCadence = try c.decodeIfPresent(String.self, forKey: .cadence) ?? "monthly"
        self.cadence = RitualCadence(rawValue: rawCadence) ?? .custom
        self.startsOn = try Self.decodeDate(c, key: .startsOn)
        self.endsOn = try Self.decodeDate(c, key: .endsOn)
        self.ritualMeaning = try c.decodeIfPresent(String.self, forKey: .ritualMeaning)
        if let rawMarker = try c.decodeIfPresent(String.self, forKey: .ritualMarkerKind) {
            // `RitualMarkerKind.none` is the canonical "no marker"
            // case; qualified explicitly to avoid Swift inferring
            // `Optional<...>.none` (= nil) from `?? .none`.
            self.ritualMarkerKind = RitualMarkerKind(rawValue: rawMarker) ?? RitualMarkerKind.none
        } else {
            self.ritualMarkerKind = nil
        }
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdByDisplayName = try c.decodeIfPresent(String.self, forKey: .createdByDisplayName)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Accept either a full ISO timestamp (`2026-05-28T00:00:00Z`) or
    /// a bare PG date (`2026-05-28`). Backend returns the latter for
    /// `date` columns — without this helper JSONDecoder fails.
    private static func decodeDate(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        guard let raw = try c.decodeIfPresent(String.self, forKey: key), !raw.isEmpty else {
            return nil
        }
        if let date = Self.dateOnlyFormatter.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

public extension GroupResourceSeries {
    /// True when the series has a ritual annotation (meaning OR marker
    /// kind other than `.none`).
    var isRitual: Bool {
        if let kind = ritualMarkerKind, kind != .none { return true }
        if let meaning = ritualMeaning, !meaning.isEmpty { return true }
        return false
    }
}
