import AppKit
import SwiftUI
import BrrrnCore

/// Deterministic README screenshot generator. `BrrrnBar --screenshots <dir>`
/// renders the real views with fixture data (never the operator's own burn)
/// and exits. Everything is seeded, so reruns produce stable images.
@MainActor
enum ScreenshotGenerator {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--screenshots") else { return }
        let directory = arguments.indices.contains(flagIndex + 1)
            ? arguments[flagIndex + 1]
            : "screenshots"
        do {
            try generate(into: URL(fileURLWithPath: directory, isDirectory: true))
            print("screenshots written to \(directory)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("screenshot generation failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func generate(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = fixtureModel()

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "rhythmUsesUTC")
        defaults.set(30, forKey: "trendDays")
        defaults.set(30, forKey: "rhythmLookback")
        defaults.set(true, forKey: "modelsExpanded")

        let tabs = ["calendar", "trend", "rhythm", "records"]
        for tab in tabs {
            defaults.set(tab, forKey: "analyticsTab")
            try render(
                BrrrnMenuView(model: model, snapshotMode: true).frame(width: 390),
                to: directory.appendingPathComponent("menu-\(tab).png")
            )
        }

        defaults.set("calendar", forKey: "analyticsTab")
        let memberModel = fixtureModel()
        memberModel.selection = fixtureSelection()
        try render(
            BrrrnMenuView(model: memberModel, snapshotMode: true).frame(width: 390),
            to: directory.appendingPathComponent("member-detail.png")
        )

        try render(
            PitSetupView(model: fixtureModel(empty: true), snapshotMode: true, onClose: {})
                .frame(width: 390),
            to: directory.appendingPathComponent("pit-setup.png")
        )
    }

    private static func render(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(
            content: view
                .background(Color(red: 0.11, green: 0.11, blue: 0.10))
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    // MARK: - Fixture data

    private static func fixtureModel(empty: Bool = false) -> AppModel {
        let model = AppModel()
        let daily = fixtureDaily()
        model.report = fixtureReport(daily: daily)
        model.weekReport = model.report
        model.lastUpdated = Date()
        if !empty {
            model.boards = [fixtureBoard()]
            model.configOverride = BrrrnConfig(hubURL: "https://hub.example", handle: "kevin", pits: ["ember-fox-7k2m"])
        } else {
            model.configOverride = BrrrnConfig(hubURL: "https://hub.example", handle: "", pits: [])
        }
        return model
    }

    /// ~5 months of plausible burn shaped around the viewer's local clock
    /// (noon-peaked workdays), stored as the UTC buckets the engine would
    /// emit. That way the local-timezone rhythm view in the README looks the
    /// way a real day looks.
    private static func fixtureDaily() -> [BurnReport.DailyEntry] {
        var random = SeededRandom(seed: 20260716)
        let local = BurnAnalytics.calendar(in: .current)
        let utc = BurnReport.DailyEntry.utcCalendar
        let todayStart = local.startOfDay(for: Date())
        var hoursByUTCDay: [Date: [Double]] = [:]

        for back in stride(from: 152, through: 0, by: -1) {
            guard let dayStart = local.date(byAdding: .day, value: -back, to: todayStart) else { continue }
            let weekday = local.component(.weekday, from: dayStart)
            let isWeekend = weekday == 1 || weekday == 7
            let recent = back <= 12
            let base: Double = if isWeekend {
                recent ? random.double(1.4...4.0) : random.double(0.2...1.6)
            } else {
                random.double(1.5...34.0)
            }
            for hour in 0..<24 {
                let shape: Double = switch hour {
                case 12...15: 1.0
                case 9...11, 16...18: 0.45
                case 21...23: 0.18
                default: 0.02
                }
                var cost = (base * shape * random.double(0.4...1.4)).rounded(toPlaces: 2)
                if back == 9 && hour == 13 { cost = 1063.79 } // the record spike
                guard cost > 0 else { continue }
                let instant = dayStart.addingTimeInterval(Double(hour) * 3600)
                let utcDay = utc.startOfDay(for: instant)
                var hours = hoursByUTCDay[utcDay] ?? [Double](repeating: 0, count: 24)
                hours[utc.component(.hour, from: instant)] += cost
                hoursByUTCDay[utcDay] = hours
            }
        }

        return hoursByUTCDay.keys.sorted().map { day in
            let hours = hoursByUTCDay[day] ?? []
            let cost = hours.reduce(0, +)
            return BurnReport.DailyEntry(
                date: BurnAnalytics.dateKey(day),
                tokens: Int(cost * 210_000),
                costUSD: cost,
                hours: hours,
                hourTokens: hours.map { Int($0 * 210_000) }
            )
        }
    }

    private static func fixtureReport(daily: [BurnReport.DailyEntry]) -> BurnReport {
        let todayUSD = daily.last?.costUSD ?? 0
        let weekUSD = daily.suffix(3).reduce(0) { $0 + $1.costUSD }
        let monthUSD = daily.suffix(16).reduce(0) { $0 + $1.costUSD }
        let allUSD = daily.reduce(0) { $0 + $1.costUSD }
        func window(_ cost: Double) -> BurnReport.Window {
            BurnReport.Window(tokens: Int(cost * 210_000), costUSD: cost, unpricedTokens: 0)
        }
        return BurnReport(
            tz: "utc",
            windows: .init(
                today: window(todayUSD),
                week: window(weekUSD),
                month: window(monthUSD),
                all: window(allUSD)
            ),
            bySource: [
                "claude": .init(todayUSD: todayUSD * 0.62, weekUSD: weekUSD * 0.62, monthUSD: monthUSD * 0.62),
                "codex": .init(todayUSD: todayUSD * 0.38, weekUSD: weekUSD * 0.38, monthUSD: monthUSD * 0.38),
            ],
            streak: .init(days: streakDays(daily: daily), thresholdUSD: 5),
            byModel: [
                .init(source: "claude", model: "claude-fable-5", speed: "standard",
                      inputTokens: 48_113_204, outputTokens: 1_952_331,
                      cacheReadTokens: 322_509_118, cacheWriteTokens: 8_113_407,
                      totalTokens: 380_688_060, costUSD: 941.52),
                .init(source: "codex", model: "gpt-5.6-sol", speed: "xhigh",
                      inputTokens: 9_804_112, outputTokens: 3_312_904, reasoningTokens: 2_101_338,
                      totalTokens: 13_117_016, costUSD: 402.19),
                .init(source: "claude", model: "claude-opus-4-8", speed: "fast",
                      inputTokens: 5_211_007, outputTokens: 604_112,
                      cacheReadTokens: 40_022_513, cacheWriteTokens: 1_002_118,
                      totalTokens: 46_839_750, costUSD: 188.06),
                .init(source: "codex", model: "gpt-5.6-sol", speed: "medium",
                      inputTokens: 3_004_211, outputTokens: 811_305, reasoningTokens: 402_113,
                      totalTokens: 3_815_516, costUSD: 84.77),
                .init(source: "codex", model: "gpt-5.3-codex", speed: "high",
                      inputTokens: 1_204_509, outputTokens: 311_970, reasoningTokens: 121_004,
                      totalTokens: 1_516_479, costUSD: 41.13),
            ],
            daily: daily
        )
    }

    private static func streakDays(daily: [BurnReport.DailyEntry]) -> Int {
        var run = 0
        for (index, entry) in daily.enumerated().reversed() {
            if entry.costUSD >= 5 {
                run += 1
            } else if index == daily.count - 1 {
                continue // incomplete today does not break the streak
            } else {
                break
            }
        }
        return run
    }

    private static func fixtureBoard() -> PitBoard {
        PitBoard(
            name: "night shift",
            code: "ember-fox-7k2m",
            streakThresholdUSD: 5,
            members: [
                .init(handle: "kevin", todayUSD: 213.40, weekUSD: 1_402.11, monthUSD: 4_799.63,
                      streakDays: 11, topModel: "claude-fable-5",
                      modelsWeek: [.init(model: "claude-fable-5", inputTokens: 48_113_204,
                                         outputTokens: 1_952_331, costUSD: 941.52)]),
                .init(handle: "mitsuha", todayUSD: 187.92, weekUSD: 1_688.04, monthUSD: 5_231.87,
                      streakDays: 24, topModel: "gpt-5.6-sol",
                      modelsWeek: [.init(model: "gpt-5.6-sol", inputTokens: 12_004_113,
                                         outputTokens: 4_113_209, costUSD: 1_020.44)]),
                .init(handle: "ryo", todayUSD: 96.51, weekUSD: 733.28, monthUSD: 2_101.09,
                      streakDays: 3, topModel: "claude-opus-4-8",
                      modelsWeek: [.init(model: "claude-opus-4-8", inputTokens: 8_311_004,
                                         outputTokens: 902_113, costUSD: 512.87)]),
                .init(handle: "ada", todayUSD: 12.03, weekUSD: 388.90, monthUSD: 1_509.32,
                      streakDays: 0, topModel: "gpt-5.3-codex",
                      modelsWeek: [.init(model: "gpt-5.3-codex", inputTokens: 2_113_400,
                                         outputTokens: 512_119, costUSD: 217.55)]),
            ]
        )
    }

    private static func fixtureSelection() -> AppModel.Selection {
        let member = fixtureBoard().members[1]
        return AppModel.Selection(
            pitCode: "ember-fox-7k2m",
            member: member,
            detail: MemberDetail(
                handle: member.handle,
                streakThresholdUSD: 5,
                days: fixtureDaily().suffix(120).map {
                    BurnReport.DailyEntry(date: $0.date, tokens: $0.tokens, costUSD: $0.costUSD * 0.9)
                }
            )
        )
    }
}

/// Tiny LCG so fixtures are identical on every run and machine.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
