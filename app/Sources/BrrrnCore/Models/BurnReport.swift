import Foundation

/// Decoded output of `brrrn --json` (and `brrrn --period week --json`).
/// The schema is frozen; unknown fields are ignored by Codable.
public struct BurnReport: Codable, Sendable, Equatable {
    public var period: String?
    public var tz: String?
    public var generatedOn: String?
    public var windows: Windows
    public var bySource: [String: SourceCosts]?
    public var streak: Streak?
    public var byModel: [ModelUsage]
    public var daily: [DailyEntry]?

    enum CodingKeys: String, CodingKey {
        case period
        case tz
        case generatedOn = "generated_on"
        case windows
        case bySource = "by_source"
        case streak
        case byModel = "by_model"
        case daily
    }

    public init(
        period: String? = nil,
        tz: String? = nil,
        generatedOn: String? = nil,
        windows: Windows,
        bySource: [String: SourceCosts]? = nil,
        streak: Streak? = nil,
        byModel: [ModelUsage] = [],
        daily: [DailyEntry]? = nil
    ) {
        self.period = period
        self.tz = tz
        self.generatedOn = generatedOn
        self.windows = windows
        self.bySource = bySource
        self.streak = streak
        self.byModel = byModel
        self.daily = daily
    }

    public struct Window: Codable, Sendable, Equatable {
        public var tokens: Int
        public var costUSD: Double
        public var unpricedTokens: Int

        enum CodingKeys: String, CodingKey {
            case tokens
            case costUSD = "cost_usd"
            case unpricedTokens = "unpriced_tokens"
        }

        public init(tokens: Int = 0, costUSD: Double = 0, unpricedTokens: Int = 0) {
            self.tokens = tokens
            self.costUSD = costUSD
            self.unpricedTokens = unpricedTokens
        }
    }

    public struct Windows: Codable, Sendable, Equatable {
        public var today: Window
        public var week: Window
        public var month: Window
        public var all: Window

        public init(today: Window, week: Window, month: Window, all: Window) {
            self.today = today
            self.week = week
            self.month = month
            self.all = all
        }
    }

    public struct SourceCosts: Codable, Sendable, Equatable {
        public var todayUSD: Double
        public var weekUSD: Double
        public var monthUSD: Double

        enum CodingKeys: String, CodingKey {
            case todayUSD = "today_usd"
            case weekUSD = "week_usd"
            case monthUSD = "month_usd"
        }

        public init(todayUSD: Double = 0, weekUSD: Double = 0, monthUSD: Double = 0) {
            self.todayUSD = todayUSD
            self.weekUSD = weekUSD
            self.monthUSD = monthUSD
        }
    }

    public struct Streak: Codable, Sendable, Equatable {
        public var days: Int
        public var thresholdUSD: Double

        enum CodingKeys: String, CodingKey {
            case days
            case thresholdUSD = "threshold_usd"
        }

        public init(days: Int, thresholdUSD: Double) {
            self.days = days
            self.thresholdUSD = thresholdUSD
        }
    }

    public struct ModelUsage: Codable, Sendable, Equatable, Identifiable {
        public var source: String
        public var model: String
        public var speed: String?
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int?
        public var cacheWriteTokens: Int?
        public var reasoningTokens: Int?
        public var totalTokens: Int
        /// May be JSON null for unpriced models.
        public var costUSD: Double?

        public var id: String { "\(source)/\(model)/\(speed ?? "")" }

        enum CodingKeys: String, CodingKey {
            case source
            case model
            case speed
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case reasoningTokens = "reasoning_tokens"
            case totalTokens = "total_tokens"
            case costUSD = "cost_usd"
        }

        public init(
            source: String,
            model: String,
            speed: String? = nil,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int? = nil,
            cacheWriteTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            totalTokens: Int = 0,
            costUSD: Double? = nil
        ) {
            self.source = source
            self.model = model
            self.speed = speed
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public struct DailyEntry: Codable, Sendable, Equatable {
        public var date: String
        public var tokens: Int
        public var costUSD: Double

        enum CodingKeys: String, CodingKey {
            case date
            case tokens
            case costUSD = "cost_usd"
        }

        public init(date: String, tokens: Int = 0, costUSD: Double = 0) {
            self.date = date
            self.tokens = tokens
            self.costUSD = costUSD
        }

        /// Parses the "yyyy-MM-dd" date string as a UTC day start.
        public var dateValue: Date? {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var components = DateComponents()
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            return Self.utcCalendar.date(from: components)
        }

        static var utcCalendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }
    }
}
