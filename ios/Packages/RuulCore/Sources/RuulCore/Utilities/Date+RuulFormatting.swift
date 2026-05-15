import Foundation

/// Date formatting helpers for Ruul UI.
///
/// Pre-Pass-3, ad-hoc `DateFormatter()` instances were sprinkled through
/// Features/ — inconsistent locale/format. These helpers centralize:
/// - locale: `.current` (auto-localizes for es-MX founder + future locales)
/// - timezone: current device timezone
/// - format: per-helper, designed for one display purpose
///
/// All formatters are cached as private statics — `DateFormatter` is expensive
/// to construct; building one per call is a common performance trap.
///
/// A SwiftLint rule `no_ad_hoc_dateformatter` (Pass 3 Task 5) will fail any
/// future `DateFormatter()` re-introduction in Features/. New display shapes
/// should be added here, not inlined.
public extension Date {

    // MARK: - Long date + time ("12 de marzo de 2026, 9:00 p.m.")

    /// Long date with short time, current locale.
    /// Replaces the `absoluteFormatter` in `SystemEventDetailView`.
    var ruulLongDateTime: String {
        Date.ruulLongDateTimeFormatter.string(from: self)
    }

    // MARK: - Long date only ("12 de marzo de 2026")

    /// Long date without time, current locale.
    /// Replaces the inline formatter in `MemberDetailView`.
    var ruulLongDate: String {
        Date.ruulLongDateFormatter.string(from: self)
    }

    // MARK: - Medium date + time ("12 mar. 2026, 9:00 p.m.")

    /// Medium date with short time, current locale.
    /// Replaces the date+time branch in `ResourceWizardSheet.displayValue(for:)`
    /// and `ResourceRowDateFormatter.short(_:)` in `AssetDetailView`.
    var ruulMediumDateTime: String {
        Date.ruulMediumDateTimeFormatter.string(from: self)
    }

    // MARK: - Medium date only ("12 mar. 2026")

    /// Medium date without time, current locale.
    /// Replaces the date-only branch in `ResourceWizardSheet.displayValue(for:)`.
    var ruulMediumDate: String {
        Date.ruulMediumDateFormatter.string(from: self)
    }

    // MARK: - Event day title ("jueves 12 de marzo")

    /// Full weekday + day + month in current locale, lowercase.
    /// Replaces `heroDateFormatter` in `ResourceSummaryView`.
    var ruulEventDayTitle: String {
        Date.ruulEventDayTitleFormatter.string(from: self)
    }

    // MARK: - Event time-of-day ("09:00 h")

    /// 24-hour time with trailing "h" suffix ("09:00 h").
    /// Replaces `heroDayFormatter` in `ResourceSummaryView`.
    var ruulEventTimeOfDay: String {
        Date.ruulEventTimeOfDayFormatter.string(from: self)
    }

    // MARK: - Relative ("hace 3 días", "ayer", "en 2 horas")

    /// Relative date/time description from now, current locale.
    /// Replaces `relativeFormatter` in `ResourceSummaryView`.
    var ruulRelative: String {
        Date.ruulRelativeFormatter.localizedString(for: self, relativeTo: .now)
    }
}

// MARK: - Cached formatters

private extension Date {

    static let ruulLongDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static let ruulLongDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    static let ruulMediumDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let ruulMediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let ruulEventDayTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d 'de' MMMM"
        return f
    }()

    static let ruulEventTimeOfDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm 'h'"
        return f
    }()

    // RelativeDateTimeFormatter is not yet Sendable in the iOS 26 SDK;
    // safe to mark nonisolated(unsafe) because the formatter is configured
    // once at initialization and then only read (never mutated post-init).
    nonisolated(unsafe) static let ruulRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
