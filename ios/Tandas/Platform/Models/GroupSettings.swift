import Foundation

/// Strongly-typed view over `groups.settings` jsonb. Consolidates the flat
/// settings columns from earlier migrations (event_label, frequency_*,
/// rotation_mode, fines_*, fund_*, etc.) into a single decoded struct.
///
/// All fields are optional so a row without a settings backfill — or a
/// future template that uses a different subset — decodes without errors.
/// Reads should fall back to `Group`'s legacy flat fields when a key is
/// nil during the 2-week paridad transition.
struct GroupSettings: Sendable, Codable, Hashable {
    // MARK: - Vocabulary + scheduling

    var eventVocabulary: String?
    var currency: String?
    var timezone: String?
    var defaultDayOfWeek: Int?
    var defaultStartTime: String?
    var defaultLocation: String?
    var frequencyType: FrequencyType?
    var frequencyConfig: FrequencyConfig?

    // MARK: - Rotation

    var rotationEnabled: Bool?
    var rotationMode: RotationMode?

    // MARK: - Fines

    var finesEnabled: Bool?
    var gracePeriodEvents: Int?
    var monthlyFineCapMxn: Decimal?
    var noShowGraceMinutes: Int?
    var autoGenerateEvents: Bool?
    var blockUnpaidAttendance: Bool?

    // MARK: - Voting / Appeals

    var committeeRequiredForAppeals: Bool?

    // MARK: - Fund

    var fundEnabled: Bool?
    var fundBalance: Decimal?
    var fundTarget: Decimal?
    var fundTargetLabel: String?
    var fundMinParticipants: Int?
    var fundAdmin: UUID?

    init() {}

    static let empty = GroupSettings()
}
