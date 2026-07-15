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

/// Hour-of-day burn profile: today against the recent typical day, bucketed
/// in the caller's display timezone.
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

/// One personal record with when it happened and whether it is being set
/// right now (today / this hour / an ongoing streak).
public struct BurnRecord: Sendable, Equatable {
    public var costUSD: Double
    public var date: Date
    public var isCurrent: Bool

    public init(costUSD: Double, date: Date, isCurrent: Bool) {
        self.costUSD = costUSD
        self.date = date
        self.isCurrent = isCurrent
    }
}

/// Gym-style PRs over the full local history.
public struct BurnRecords: Sendable, Equatable {
    /// Highest single UTC-hour burn. `date` is the exact hour instant.
    public var bestHour: BurnRecord?
    /// Highest single UTC-day burn. `date` is the UTC day start.
    public var bestDay: BurnRecord?
    /// Longest streak of consecutive UTC days at or above the threshold.
    public var longestStreakDays: Int
    /// Last day of the longest streak (UTC day start).
    public var longestStreakEnd: Date?
    /// True when the longest streak is the one running right now.
    public var longestStreakIsCurrent: Bool

    public init(
        bestHour: BurnRecord? = nil,
        bestDay: BurnRecord? = nil,
        longestStreakDays: Int = 0,
        longestStreakEnd: Date? = nil,
        longestStreakIsCurrent: Bool = false
    ) {
        self.bestHour = bestHour
        self.bestDay = bestDay
        self.longestStreakDays = longestStreakDays
        self.longestStreakEnd = longestStreakEnd
        self.longestStreakIsCurrent = longestStreakIsCurrent
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

    /// Hour-of-day profile in `timeZone`. The engine stores UTC day plus UTC
    /// hour, which pins every bucket to an absolute instant, so re-bucketing
    /// into the viewer's timezone is exact at hour granularity: no rescan,
    /// and the social UTC aggregates stay untouched. `typicalByHour` averages
    /// the `lookbackDays` local days before today that saw any burn, so an
    /// idle weekend does not dilute the shape of a normal working day.
    public static func rhythm(
        entries: [BurnReport.DailyEntry],
        lookbackDays: Int = 30,
        endingAt end: Date = Date(),
        timeZone: TimeZone = .current
    ) -> BurnRhythm {
        let calendar = calendar(in: timeZone)
        let todayStart = calendar.startOfDay(for: end)
        guard
            let firstDay = calendar.date(byAdding: .day, value: -max(1, lookbackDays), to: todayStart),
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)
        else {
            return BurnRhythm(
                todayByHour: [Double](repeating: 0, count: 24),
                typicalByHour: [Double](repeating: 0, count: 24),
                activeDays: 0
            )
        }

        var today = [Double](repeating: 0, count: 24)
        var costByDayHour: [Date: [Double]] = [:]

        for (instant, cost) in hourInstants(entries: entries) where cost > 0 {
            if instant >= todayStart && instant < tomorrowStart {
                today[calendar.component(.hour, from: instant)] += cost
                continue
            }
            guard instant >= firstDay && instant < todayStart else { continue }
            let day = calendar.startOfDay(for: instant)
            var hours = costByDayHour[day] ?? [Double](repeating: 0, count: 24)
            hours[calendar.component(.hour, from: instant)] += cost
            costByDayHour[day] = hours
        }

        var typical = [Double](repeating: 0, count: 24)
        let activeDays = costByDayHour.count
        if activeDays > 0 {
            for hours in costByDayHour.values {
                for hour in 0..<24 { typical[hour] += hours[hour] }
            }
            for hour in 0..<24 { typical[hour] /= Double(activeDays) }
        }
        return BurnRhythm(todayByHour: today, typicalByHour: typical, activeDays: activeDays)
    }

    /// Personal records over the full history carried in `entries`. Day and
    /// streak records stay on UTC days so they mean the same thing as the
    /// numbers friends compare on the board; the hour record is an absolute
    /// instant and can be rendered in any timezone.
    public static func records(
        entries: [BurnReport.DailyEntry],
        thresholdUSD: Double = StreakPolicy.defaultThresholdUSD,
        endingAt end: Date = Date()
    ) -> BurnRecords {
        let calendar = BurnReport.DailyEntry.utcCalendar
        let todayStart = calendar.startOfDay(for: end)
        let todayKey = dateKey(todayStart)

        var costByKey: [String: Double] = [:]
        for entry in entries {
            costByKey[entry.date, default: 0] += entry.costUSD
        }

        var bestDay: BurnRecord?
        for (key, cost) in costByKey where cost > 0 {
            guard cost > (bestDay?.costUSD ?? 0),
                  let day = BurnReport.DailyEntry(date: key).dateValue
            else { continue }
            bestDay = BurnRecord(costUSD: cost, date: day, isCurrent: key == todayKey)
        }

        var bestHour: BurnRecord?
        for (instant, cost) in hourInstants(entries: entries) where cost > 0 {
            guard cost > (bestHour?.costUSD ?? 0) else { continue }
            let isCurrent = calendar.startOfDay(for: instant) == todayStart
            bestHour = BurnRecord(costUSD: cost, date: instant, isCurrent: isCurrent)
        }

        var longest = 0
        var longestEnd: Date?
        var runLength = 0
        var previousDay: Date?
        var currentRunEnd: Date?
        for key in costByKey.keys.sorted() {
            guard costByKey[key, default: 0] >= thresholdUSD,
                  let day = BurnReport.DailyEntry(date: key).dateValue
            else { continue }
            let continues = previousDay.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day
            runLength = continues ? runLength + 1 : 1
            previousDay = day
            currentRunEnd = day
            if runLength > longest {
                longest = runLength
                longestEnd = day
            }
        }
        // The longest streak is "current" when its run reaches today, or
        // yesterday with today still below the threshold (the day is not
        // over, matching the live streak rule).
        var longestIsCurrent = false
        if let longestEnd, longestEnd == currentRunEnd {
            if longestEnd == todayStart {
                longestIsCurrent = true
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
                      longestEnd == yesterday,
                      costByKey[todayKey, default: 0] < thresholdUSD {
                longestIsCurrent = true
            }
        }

        return BurnRecords(
            bestHour: bestHour,
            bestDay: bestDay,
            longestStreakDays: longest,
            longestStreakEnd: longestEnd,
            longestStreakIsCurrent: longestIsCurrent
        )
    }

    public static func dateKey(_ date: Date) -> String {
        let components = BurnReport.DailyEntry.utcCalendar
            .dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    /// Every stored (UTC day, hour) bucket as an absolute instant with its
    /// cost. Entries from engines without hourly tracking contribute nothing.
    static func hourInstants(entries: [BurnReport.DailyEntry]) -> [(Date, Double)] {
        var instants: [(Date, Double)] = []
        for entry in entries {
            guard let hours = entry.hours, hours.count == 24,
                  let dayStart = entry.dateValue
            else { continue }
            for hour in 0..<24 where hours[hour] != 0 {
                instants.append((dayStart.addingTimeInterval(Double(hour) * 3600), hours[hour]))
            }
        }
        return instants
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
