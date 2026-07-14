import Foundation

/// Decoded response of `GET {hub_url}/pit/{code}/board`. Schema is frozen.
public struct PitBoard: Codable, Sendable, Equatable {
    public var name: String?
    public var code: String
    public var streakThresholdUSD: Double?
    public var members: [Member]

    enum CodingKeys: String, CodingKey {
        case name
        case code
        case streakThresholdUSD = "streak_threshold_usd"
        case members
    }

    public init(
        name: String?,
        code: String,
        streakThresholdUSD: Double? = nil,
        members: [Member]
    ) {
        self.name = name
        self.code = code
        self.streakThresholdUSD = streakThresholdUSD
        self.members = members
    }

    public var effectiveStreakThresholdUSD: Double {
        streakThresholdUSD ?? StreakPolicy.defaultThresholdUSD
    }

    /// Members ranked by today's burn, descending. Ties break on week burn,
    /// then handle, so ordering is stable.
    public var rankedMembers: [Member] {
        members.sorted { a, b in
            if a.todayUSD != b.todayUSD { return a.todayUSD > b.todayUSD }
            if a.weekUSD != b.weekUSD { return a.weekUSD > b.weekUSD }
            return a.handle.localizedCaseInsensitiveCompare(b.handle) == .orderedAscending
        }
    }

    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public var handle: String
        public var todayUSD: Double
        public var weekUSD: Double
        public var monthUSD: Double
        public var streakDays: Int
        public var topModel: String?
        public var modelsWeek: [ModelWeek]?

        public var id: String { handle }

        enum CodingKeys: String, CodingKey {
            case handle
            case todayUSD = "today_usd"
            case weekUSD = "week_usd"
            case monthUSD = "month_usd"
            case streakDays = "streak_days"
            case topModel = "top_model"
            case modelsWeek = "models_week"
        }

        public init(
            handle: String,
            todayUSD: Double = 0,
            weekUSD: Double = 0,
            monthUSD: Double = 0,
            streakDays: Int = 0,
            topModel: String? = nil,
            modelsWeek: [ModelWeek]? = nil
        ) {
            self.handle = handle
            self.todayUSD = todayUSD
            self.weekUSD = weekUSD
            self.monthUSD = monthUSD
            self.streakDays = streakDays
            self.topModel = topModel
            self.modelsWeek = modelsWeek
        }
    }

    public struct ModelWeek: Codable, Sendable, Equatable, Identifiable {
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var costUSD: Double?

        public var id: String { model }

        enum CodingKeys: String, CodingKey {
            case model
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case costUSD = "cost_usd"
        }

        public init(model: String, inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double? = nil) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
        }
    }
}

/// Decoded response of `GET {hub_url}/pit/{code}/member/{handle}`.
public struct MemberDetail: Codable, Sendable, Equatable {
    public var handle: String
    public var streakThresholdUSD: Double?
    public var days: [BurnReport.DailyEntry]

    enum CodingKeys: String, CodingKey {
        case handle
        case streakThresholdUSD = "streak_threshold_usd"
        case days
    }

    public init(
        handle: String,
        streakThresholdUSD: Double? = nil,
        days: [BurnReport.DailyEntry]
    ) {
        self.handle = handle
        self.streakThresholdUSD = streakThresholdUSD
        self.days = days
    }

    public var effectiveStreakThresholdUSD: Double {
        streakThresholdUSD ?? StreakPolicy.defaultThresholdUSD
    }
}

/// One bar in the drill-down chart.
public struct DailyPoint: Sendable, Equatable, Identifiable {
    public var date: Date
    public var costUSD: Double

    public var id: Date { date }

    public init(date: Date, costUSD: Double) {
        self.date = date
        self.costUSD = costUSD
    }
}

extension MemberDetail {
    /// A dense series of the trailing `count` UTC days ending at `end`,
    /// filling days with no data as zero so the chart has an even baseline.
    public func series(days count: Int = 14, endingAt end: Date = Date()) -> [DailyPoint] {
        let calendar = BurnReport.DailyEntry.utcCalendar
        let endDay = calendar.startOfDay(for: end)
        var costByDay: [Date: Double] = [:]
        for entry in days {
            if let day = entry.dateValue {
                costByDay[day] = entry.costUSD
            }
        }
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            return DailyPoint(date: day, costUSD: costByDay[day] ?? 0)
        }
    }
}
