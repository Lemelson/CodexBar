import Foundation

/// Panel labels: short and in English, like the rest of CodexBar.
public enum UsageFormat {
    private static let locale = Locale(identifier: "en_US_POSIX")
    /// One formatter per pattern: the menu formats dozens of dates on every rebuild. `NSCache` is thread-safe.
    private nonisolated(unsafe) static let formatters = NSCache<NSString, DateFormatter>()

    public static func usd(_ value: Double) -> String {
        if value < 0.5 {
            return "$0"
        }
        if value < 10 {
            return "$" + String(format: "%.1f", value)
        }
        return "$" + self.grouped(value.rounded())
    }

    public static func tokens(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...:
            self.decimal(value / 1_000_000_000) + "B"
        case 1_000_000...:
            self.decimal(value / 1_000_000) + "M"
        case 1000...:
            self.decimal(value / 1000) + "K"
        default:
            "\(Int(value.rounded()))"
        }
    }

    public static func percent(_ value: Double) -> String {
        if value > 0, value < 0.5 {
            return "<1%"
        }
        return "\(Int(value.rounded()))%"
    }

    public static func times(_ value: Double) -> String {
        "×\(Int(value.rounded()))"
    }

    /// «3h 40m», «45m», «2d 4h».
    public static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 {
            return "\(minutes)m"
        }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
        }
        let hours = minutes / 60
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "resets in 3h 12m" or "resets Tue 11:00".
    public static func reset(_ timestamp: Double, now: Date) -> String {
        let delta = timestamp - now.timeIntervalSince1970
        if delta <= 0 {
            return "window has reset"
        }
        if delta < 24 * 3600 {
            return "resets in \(self.duration(delta))"
        }
        return "resets \(self.weekdayTime(timestamp))"
    }

    /// "just now", "52m ago", "1h ago", "3d ago": whole units only, no minutes once it is an hour.
    public static func age(_ timestamp: Double, now: Date) -> String {
        let delta = now.timeIntervalSince1970 - timestamp
        if delta < 90 {
            return "just now"
        }
        let minutes = Int(delta / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    /// Today's time is "04:19", otherwise "Nov 21, 14:05".
    public static func stamp(_ timestamp: Double, now: Date) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        return self.format(date, Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm")
    }

    public static func clock(_ date: Date) -> String {
        self.format(date, "HH:mm")
    }

    public static func shortDay(_ timestamp: Double) -> String {
        self.format(Date(timeIntervalSince1970: timestamp), "MMM d")
    }

    public static func weekdayTime(_ timestamp: Double) -> String {
        self.format(Date(timeIntervalSince1970: timestamp), "EEE HH:mm")
    }

    public static func weekday(_ date: Date) -> String {
        self.format(date, "EEE")
    }

    public static func dayRange(_ start: Double, _ end: Double) -> String {
        "\(self.shortDay(start)) – \(self.shortDay(end))"
    }

    public static func format(_ date: Date, _ pattern: String) -> String {
        let key = pattern as NSString
        if let cached = self.formatters.object(forKey: key) {
            return cached.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = self.locale
        formatter.dateFormat = pattern
        self.formatters.setObject(formatter, forKey: key)
        return formatter.string(from: date)
    }

    private static func grouped(_ value: Double) -> String {
        let digits = String(Int(value))
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }

    private static func decimal(_ value: Double) -> String {
        if value >= 100 {
            return String(Int(value.rounded()))
        }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
