import Foundation

public enum StreakPolicy {
    public static let defaultThresholdUSD = 5.0
}

public enum DailyCostLevel: Int, CaseIterable, Sendable, Equatable {
    case none
    case belowThreshold
    case active
    case high
    case veryHigh
    case extreme
}

public enum DailyActivityStatus: Sendable, Equatable {
    case future
    case noUsage
    case unpriced
    case belowThreshold
    case thresholdMet
    case currentStreak
}

public struct DailyActivityCell: Identifiable, Sendable, Equatable {
    public var date: Date
    public var dateKey: String
    public var tokens: Int
    public var costUSD: Double
    public var hasRecord: Bool
    public var isFuture: Bool
    public var isToday: Bool
    public var weekIndex: Int
    public var weekdayIndex: Int
    public var level: DailyCostLevel
    public var status: DailyActivityStatus

    public var id: String { dateKey }
}

public struct UTCActivityGrid: Sendable, Equatable {
    public var cells: [DailyActivityCell]
    public var weeks: Int
    public var thresholdUSD: Double
    public var currentStreakDays: Int
    public var startDate: Date
    public var endDate: Date

    public var startDateKey: String { Self.dateKey(startDate) }
    public var endDateKey: String { Self.dateKey(endDate) }

    public init(
        entries: [BurnReport.DailyEntry],
        weeks: Int,
        endingAt end: Date = Date(),
        thresholdUSD: Double = StreakPolicy.defaultThresholdUSD
    ) {
        let calendar = BurnReport.DailyEntry.utcCalendar
        let weekCount = max(1, weeks)
        let effectiveThreshold = thresholdUSD.isFinite && thresholdUSD > 0
            ? thresholdUSD
            : StreakPolicy.defaultThresholdUSD
        let endDay = calendar.startOfDay(for: end)
        let weekday = calendar.component(.weekday, from: endDay)
        let daysSinceMonday = (weekday + 5) % 7
        let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: endDay)!
        let firstDay = calendar.date(byAdding: .day, value: -(weekCount - 1) * 7, to: currentWeekStart)!

        var values: [String: (tokens: Int, cost: Double)] = [:]
        for entry in entries where entry.dateValue != nil {
            let prior = values[entry.date] ?? (0, 0)
            values[entry.date] = (prior.tokens + entry.tokens, prior.cost + entry.costUSD)
        }

        var streakDates = Set<String>()
        var cursor = endDay
        if (values[Self.dateKey(cursor)]?.cost ?? 0) < effectiveThreshold {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        while (values[Self.dateKey(cursor)]?.cost ?? 0) >= effectiveThreshold {
            streakDates.insert(Self.dateKey(cursor))
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        var built: [DailyActivityCell] = []
        built.reserveCapacity(weekCount * 7)
        for offset in 0..<(weekCount * 7) {
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            let key = Self.dateKey(day)
            let value = values[key]
            let cost = value?.cost ?? 0
            let tokens = value?.tokens ?? 0
            let future = day > endDay
            let level = Self.level(cost: cost, threshold: effectiveThreshold, isFuture: future)
            let status = Self.status(
                cost: cost,
                tokens: tokens,
                hasRecord: value != nil,
                isFuture: future,
                isCurrentStreak: streakDates.contains(key),
                threshold: effectiveThreshold
            )
            built.append(DailyActivityCell(
                date: day,
                dateKey: key,
                tokens: tokens,
                costUSD: cost,
                hasRecord: value != nil,
                isFuture: future,
                isToday: day == endDay,
                weekIndex: offset / 7,
                weekdayIndex: offset % 7,
                level: level,
                status: status
            ))
        }

        cells = built
        self.weeks = weekCount
        self.thresholdUSD = effectiveThreshold
        currentStreakDays = streakDates.count
        startDate = firstDay
        endDate = endDay
    }

    private static func level(cost: Double, threshold: Double, isFuture: Bool) -> DailyCostLevel {
        if isFuture || cost <= 0 { return .none }
        if cost < threshold { return .belowThreshold }
        if cost < threshold * 5 { return .active }
        if cost < threshold * 20 { return .high }
        if cost < threshold * 100 { return .veryHigh }
        return .extreme
    }

    private static func status(
        cost: Double,
        tokens: Int,
        hasRecord: Bool,
        isFuture: Bool,
        isCurrentStreak: Bool,
        threshold: Double
    ) -> DailyActivityStatus {
        if isFuture { return .future }
        if !hasRecord { return .noUsage }
        if cost <= 0 && tokens > 0 { return .unpriced }
        if cost < threshold { return .belowThreshold }
        if isCurrentStreak { return .currentStreak }
        return .thresholdMet
    }

    private static func dateKey(_ date: Date) -> String {
        let components = BurnReport.DailyEntry.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
