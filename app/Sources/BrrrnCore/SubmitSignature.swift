import Foundation

/// A fingerprint of the data `brrrn submit` would push to a joined pit.
///
/// Once a pit is backfilled the CLI only sends today's and yesterday's UTC day
/// totals, so a re-submit whose fingerprint matches the last one would write
/// byte-identical records. The menu bar app compares fingerprints and skips the
/// submit entirely when nothing changed, which keeps idle machines off the hub.
public enum SubmitSignature {
    /// Fingerprint of the current push window (today and yesterday, UTC).
    /// `daily` is the `daily` slice of `brrrn --json`; `now` is injectable so
    /// the policy is deterministic under test.
    public static func of(daily: [BurnReport.DailyEntry], now: Date = Date()) -> String {
        let today = dayString(now)
        let yesterday = dayString(now.addingTimeInterval(-86_400))
        let window: Set<String> = [today, yesterday]
        return daily
            .filter { window.contains($0.date) }
            .sorted { $0.date < $1.date }
            .map { "\($0.date):\($0.tokens):\(money($0.costUSD))" }
            .joined(separator: "|")
    }

    /// UTC calendar day for an instant, formatted as the engine writes it.
    private static func dayString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Microdollar precision matches the hub's stored rounding, so cosmetic
    /// float noise below a millionth of a dollar never forces a needless push.
    private static func money(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
