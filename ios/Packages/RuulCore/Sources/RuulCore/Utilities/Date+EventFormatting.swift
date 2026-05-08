import Foundation

public extension Date {
    /// "mañana", "hoy", "en 2 horas", "el martes 3", etc.
    public var ruulRelativeDescription: String {
        let calendar = Calendar.current
        let now = Date.now
        let interval = self.timeIntervalSince(now)

        if calendar.isDateInToday(self) {
            if interval < 0 { return "hoy" }
            if interval < 3600 { return "en \(Int(interval / 60)) min" }
            return "hoy a las \(self.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(self) {
            return "mañana a las \(self.ruulShortTime)"
        }
        if calendar.isDateInYesterday(self) {
            return "ayer"
        }
        let daysAhead = calendar.dateComponents([.day], from: now, to: self).day ?? 0
        if daysAhead > 0, daysAhead < 7 {
            return "el \(self.ruulWeekday) a las \(self.ruulShortTime)"
        }
        return self.ruulFullDate
    }

    public var ruulShortTime: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "HH:mm"
        return f.string(from: self)
    }

    public var ruulWeekday: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE"
        return f.string(from: self).capitalized
    }

    public var ruulFullDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: self).capitalized
    }

    public var ruulShortDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: self).capitalized
    }

    /// "el martes 3 de octubre a las 20:30"
    public var ruulFullDateTime: String {
        "\(ruulFullDate) a las \(ruulShortTime)"
    }
}
