import Foundation

/// Display formatting shared by the menu bar label and the dropdown.
/// Locale is pinned to en_US so numbers render identically everywhere.
public enum Format {
    /// Money rule: at or above $100 round to whole dollars with a thousands
    /// separator ("$1,342"); below that keep two decimals ("$99.50").
    public static func money(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        if abs(amount) >= 100 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        return formatter.string(from: NSNumber(value: amount)) ?? "$0"
    }

    /// Token humanization: 999 stays "999", thousands and millions get one
    /// decimal ("1.2K", "3.4M"), billions get two ("2.10B").
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch count {
        case ..<1_000:
            return String(count)
        case ..<1_000_000:
            return String(format: "%.1fK", value / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1fM", value / 1_000_000)
        default:
            return String(format: "%.2fB", value / 1_000_000_000)
        }
    }

    public static func utcDate(_ date: Date) -> String {
        utcFormatter("EEEE, MMMM d, yyyy").string(from: date) + " UTC"
    }

    public static func utcMonthDay(_ date: Date) -> String {
        utcFormatter("MMM d").string(from: date)
    }

    public static func utcMonth(_ date: Date) -> String {
        utcFormatter("MMM").string(from: date)
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// Relative "last updated" text for the footer.
    public static func relativeTime(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 15 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
