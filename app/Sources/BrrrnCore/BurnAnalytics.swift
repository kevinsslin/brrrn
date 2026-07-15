import Foundation

/// One gap-filled day on the burn trend line.
public struct BurnTrendPoint: Identifiable, Sendable, Equatable {
    public var date: Date
    public var dateKey: String
    public var costUSD: Double

    public var id: String { dateKey }

    public init(date: Date, dateKey: String, costUSD: Double) {
        self.date = date
        self.dateKey = dateKey
        self.costUSD = costUSD
    }
}

/// Hour-of-day burn profile: today against the recent typical day.
public struct BurnRhythm: Sendable, Equatable {
    /// Cost per hour for the current day (24 buckets).
    public var todayByHour: [Double]
    /// Mean cost per hour across recent active days, excluding today.
    public var typicalByHour: [Double]
    /// Number of active days behind `typicalByHour`.
    public var activeDays: Int

    public var hasData: Bool {
        activeDays > 0 || todayByHour.contains(where: { $0 > 0 })
    }

    public var peakTypicalHour: Int? {
        let peak = typicalByHour.enumerated().max(by: { $0.element < $1.element })
        guard let peak, peak.element > 0 else { return nil }
        return peak.offset
    }

    public init(todayByHour: [Double], typicalByHour: [Double], activeDays: Int) {
        self.todayByHour = todayByHour
        self.typicalByHour = typicalByHour
        self.activeDays = activeDays
    }
}

public enum BurnAnalytics {
    /// Last `days` calendar days ending at `end`, gap-filled with zero-cost
    /// points so the trend line spans quiet days instead of skipping them.
    public static func trend(
        entries: [BurnReport.DailyEntry],
        days: Int,
        endingAt end: Date = Date()
    ) -> [BurnTrendPoint] {
        let calendar = BurnReport.DailyEntry.utcCalendar
        let endDay = calendar.startOfDay(for: end)
        let span = max(1, days)

        var costByKey: [String: Double] = [:]
        for entry in entries {
            costByKey[entry.date, default: 0] += entry.costUSD
        }

        return (0..<span).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - (span - 1), to: endDay) else {
                return nil
            }
            let key = dateKey(day)
            return BurnTrendPoint(date: day, dateKey: key, costUSD: costByKey[key] ?? 0)
        }
    }

    /// Hour-of-day profile from per-day hourly costs. `typicalByHour` averages
    /// the `lookbackDays` days before today that saw any burn, so an idle
    /// weekend does not dilute the shape of a normal working day.
    public static func rhythm(
        entries: [BurnReport.DailyEntry],
        lookbackDays: Int = 14,
        endingAt end: Date = Date()
    ) -> BurnRhythm {
        let calendar = BurnReport.DailyEntry.utcCalendar
        let endDay = calendar.startOfDay(for: end)
        let todayKey = dateKey(endDay)
        let firstDay = calendar.date(byAdding: .day, value: -max(1, lookbackDays), to: endDay)
        let firstKey = firstDay.map(dateKey)

        var today = [Double](repeating: 0, count: 24)
        var typical = [Double](repeating: 0, count: 24)
        var activeDays = 0

        for entry in entries {
            guard let hours = entry.hours, hours.count == 24 else { continue }
            if entry.date == todayKey {
                for hour in 0..<24 { today[hour] += hours[hour] }
                continue
            }
            guard let firstKey, entry.date >= firstKey, entry.date < todayKey else { continue }
            guard hours.contains(where: { $0 > 0 }) else { continue }
            activeDays += 1
            for hour in 0..<24 { typical[hour] += hours[hour] }
        }

        if activeDays > 0 {
            for hour in 0..<24 { typical[hour] /= Double(activeDays) }
        }
        return BurnRhythm(todayByHour: today, typicalByHour: typical, activeDays: activeDays)
    }

    public static func dateKey(_ date: Date) -> String {
        let components = BurnReport.DailyEntry.utcCalendar
            .dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
