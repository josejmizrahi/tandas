import Foundation

/// Strongly-typed view over `groups.settings` jsonb. Consolidates the flat
/// settings columns from earlier migrations (event_label, frequency_*,
/// rotation_mode, fines_*, fund_*, etc.) into a single decoded struct.
///
/// All fields are optional so a row without a settings backfill — or a
/// future template that uses a different subset — decodes without errors.
/// Reads should fall back to `Group`'s legacy flat fields when a key is
/// nil during the 2-week paridad transition.
public struct GroupSettings: Sendable, Codable, Hashable {
    // MARK: - Vocabulary + scheduling

    public var eventVocabulary: String?
    public var currency: String?
    public var timezone: String?
    public var defaultDayOfWeek: Int?
    public var defaultStartTime: String?
    public var defaultLocation: String?
    public var frequencyType: FrequencyType?
    public var frequencyConfig: FrequencyConfig?

    // MARK: - Rotation

    public var rotationEnabled: Bool?
    public var rotationMode: RotationMode?

    // MARK: - Fines

    public var finesEnabled: Bool?
    public var gracePeriodEvents: Int?
    public var monthlyFineCapMxn: Decimal?
    public var noShowGraceMinutes: Int?
    public var autoGenerateEvents: Bool?
    public var blockUnpaidAttendance: Bool?

    // MARK: - Voting / Appeals

    public var committeeRequiredForAppeals: Bool?

    // MARK: - Fund

    public var fundEnabled: Bool?
    public var fundBalance: Decimal?
    public var fundTarget: Decimal?
    public var fundTargetLabel: String?
    public var fundMinParticipants: Int?
    public var fundAdmin: UUID?

    public init() {}

    public static let empty = GroupSettings()
}
