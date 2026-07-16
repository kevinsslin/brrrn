import XCTest
@testable import BrrrnCore

final class BrrrnCoreTests: XCTestCase {
    func testBurnReportDecodesOptionalModelsByPeriod() throws {
        let data = #"{"windows":{"today":{"tokens":0,"cost_usd":0,"unpriced_tokens":0},"week":{"tokens":0,"cost_usd":0,"unpriced_tokens":0},"month":{"tokens":0,"cost_usd":0,"unpriced_tokens":0},"all":{"tokens":0,"cost_usd":0,"unpriced_tokens":0}},"by_model":[],"models_by_period":{"today":[{"source":"codex","model":"today-model","input_tokens":1,"output_tokens":2,"total_tokens":3,"cost_usd":4}],"week":[{"source":"codex","model":"week-model","input_tokens":1,"output_tokens":2,"total_tokens":3,"cost_usd":4}],"month":[{"source":"codex","model":"month-model","input_tokens":1,"output_tokens":2,"total_tokens":3,"cost_usd":4}]}}"#.data(using: .utf8)!

        let report = try JSONDecoder().decode(BurnReport.self, from: data)

        XCTAssertEqual(report.modelsByPeriod?.today.map(\.model), ["today-model"])
        XCTAssertEqual(report.modelsByPeriod?.week.map(\.model), ["week-model"])
        XCTAssertEqual(report.modelsByPeriod?.month.map(\.model), ["month-model"])
    }

    func testBurnReportDecodesFrozenSchemaIncludingNullCost() throws {
        let data = #"""
        {
          "period":"all","tz":"utc","generated_on":"2026-07-13",
          "windows":{
            "today":{"tokens":100,"cost_usd":9.5,"unpriced_tokens":3},
            "week":{"tokens":200,"cost_usd":15,"unpriced_tokens":3},
            "month":{"tokens":300,"cost_usd":25,"unpriced_tokens":3},
            "all":{"tokens":400,"cost_usd":35,"unpriced_tokens":3}
          },
          "by_source":{"claude":{"today_usd":2,"week_usd":4,"month_usd":8},"codex":{"today_usd":7.5,"week_usd":11,"month_usd":17}},
          "streak":{"days":12,"threshold_usd":5},
          "by_model":[
            {"source":"codex","model":"unknown","speed":"default","input_tokens":10,"output_tokens":2,"cache_read_tokens":5,"cache_write_tokens":0,"reasoning_tokens":1,"total_tokens":17,"cost_usd":null}
          ],
          "daily":[{"date":"2026-07-13","tokens":100,"cost_usd":9.5}]
        }
        """#.data(using: .utf8)!

        let report = try JSONDecoder().decode(BurnReport.self, from: data)
        XCTAssertEqual(report.tz, "utc")
        XCTAssertEqual(report.windows.today.costUSD, 9.5)
        XCTAssertEqual(report.bySource?["codex"]?.weekUSD, 11)
        XCTAssertEqual(report.streak?.days, 12)
        XCTAssertNil(report.byModel[0].costUSD)
        XCTAssertNil(report.modelsByPeriod)
        XCTAssertEqual(report.daily?.first?.dateValue, utcDate(2026, 7, 13))
    }

    func testPitBoardAndMemberDetailDecode() throws {
        let boardData = #"{"name":null,"code":"ember-fox-x7kq","members":[{"handle":"kevin","today_usd":10,"week_usd":20,"month_usd":30,"streak_days":3,"top_model":"fable","models_week":[{"model":"fable","input_tokens":100,"output_tokens":10,"cost_usd":8}]}]}"#.data(using: .utf8)!
        let board = try JSONDecoder().decode(PitBoard.self, from: boardData)
        XCTAssertNil(board.name)
        XCTAssertEqual(board.members[0].modelsWeek?[0].inputTokens, 100)

        let memberData = #"{"handle":"kevin","days":[{"date":"2026-07-13","tokens":20,"cost_usd":5}]}"#.data(using: .utf8)!
        let detail = try JSONDecoder().decode(MemberDetail.self, from: memberData)
        XCTAssertEqual(detail.days[0].costUSD, 5)
        XCTAssertEqual(detail.series(days: 1, endingAt: utcDate(2026, 7, 13))[0].costUSD, 5)
    }

    func testMoneyFormattingRule() {
        XCTAssertEqual(Format.money(99.5), "$99.50")
        XCTAssertEqual(Format.money(100), "$100")
        XCTAssertEqual(Format.money(1342.49), "$1,342")
        XCTAssertEqual(Format.money(0), "$0.00")
    }

    func testTokenHumanization() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1_200), "1.2K")
        XCTAssertEqual(Format.tokens(3_400_000), "3.4M")
        XCTAssertEqual(Format.tokens(2_100_000_000), "2.10B")
    }

    func testUTCActivityDateFormatting() {
        let date = utcDate(2026, 7, 14)
        XCTAssertEqual(Format.utcDate(date), "Tuesday, July 14, 2026 UTC")
        XCTAssertEqual(Format.utcMonthDay(date), "Jul 14")
        XCTAssertEqual(Format.utcMonth(date), "Jul")
    }

    func testBinaryLookupOrderAndOverride() {
        let existing = Set(["/custom/brrrn", "/Applications/BrrrnBar.app/Contents/MacOS/brrrn"])
        let locator = BinaryLocator(
            environment: ["BRRRN_BIN": "/custom/brrrn"],
            homeDirectory: "/Users/test",
            executablePath: "/Applications/BrrrnBar.app/Contents/MacOS/BrrrnBar",
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(locator.candidates(), [
            "/custom/brrrn",
            "/Applications/BrrrnBar.app/Contents/MacOS/brrrn",
            "/opt/homebrew/bin/brrrn",
            "/usr/local/bin/brrrn",
            "/Users/test/repos/kevin-dev/brrrn/target/release/brrrn",
        ])
        XCTAssertEqual(locator.locate(), "/custom/brrrn")
    }

    func testModelSortIsCostFirstAndUnpricedLast() {
        let models = [
            model("unknown", cost: nil, tokens: 9999),
            model("cheap", cost: 2, tokens: 20),
            model("expensive", cost: 8, tokens: 10),
        ]
        XCTAssertEqual(ModelSort.byCostDescending(models).map(\.model), ["expensive", "cheap", "unknown"])
    }

    func testBoardRankingIsStable() {
        let board = PitBoard(name: "crew", code: "c", members: [
            .init(handle: "low", todayUSD: 1, weekUSD: 100),
            .init(handle: "beta", todayUSD: 5, weekUSD: 10),
            .init(handle: "alpha", todayUSD: 5, weekUSD: 10),
        ])
        XCTAssertEqual(board.rankedMembers.map(\.handle), ["alpha", "beta", "low"])
    }

    func testConfigParsesCLIShapeAndPreservesSharedFields() throws {
        let data = #"{"hub_url":"https://hub.example","handle":"kevin","secret":"s","machine_id":"m","pits":["one","two"],"relationships":["rel_one"],"backfilled_pits":["one"],"future":{"enabled":true}}"#.data(using: .utf8)!
        let config = try BrrrnConfig.load(from: data)
        XCTAssertEqual(config.hubURL, "https://hub.example")
        XCTAssertEqual(config.handle, "kevin")
        XCTAssertEqual(config.pits, ["one", "two"])
        XCTAssertEqual(config.relationships, ["rel_one"])
        XCTAssertEqual(config.backfilledPits, ["one"])

        let encoded = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["future"] as? [String: Bool])?["enabled"], true)
    }

    func testConfigDefaultsMissingKnownFieldsButRejectsNullKnownFields() throws {
        let missing = try BrrrnConfig.load(from: Data("{}".utf8))
        XCTAssertEqual(missing.hubURL, "")
        XCTAssertEqual(missing.handle, "")
        XCTAssertEqual(missing.pits, [])
        XCTAssertEqual(missing.relationships, [])
        XCTAssertEqual(missing.backfilledPits, [])

        for json in [
            #"{"hub_url":null}"#,
            #"{"handle":null}"#,
            #"{"pits":null}"#,
            #"{"relationships":null}"#,
            #"{"backfilled_pits":null}"#,
        ] {
            XCTAssertThrowsError(try BrrrnConfig.load(from: Data(json.utf8)))
        }
    }

    func testConfigPathEnvironmentOverride() {
        let url = BrrrnConfig.defaultURL(
            homeDirectory: "/Users/test",
            environment: ["BRRRN_CONFIG": "/tmp/custom-brrrn.json"]
        )
        XCTAssertEqual(url.path, "/tmp/custom-brrrn.json")
    }

    func testSocialStreakThresholdDecodesAndDefaultsForOlderHubs() throws {
        let boardData = #"{"name":"crew","code":"c","streak_threshold_usd":7,"members":[]}"#.data(using: .utf8)!
        let board = try JSONDecoder().decode(PitBoard.self, from: boardData)
        XCTAssertEqual(board.streakThresholdUSD, 7)
        XCTAssertEqual(board.effectiveStreakThresholdUSD, 7)

        let legacyBoardData = #"{"name":"crew","code":"c","members":[]}"#.data(using: .utf8)!
        let legacyBoard = try JSONDecoder().decode(PitBoard.self, from: legacyBoardData)
        XCTAssertNil(legacyBoard.streakThresholdUSD)
        XCTAssertEqual(legacyBoard.effectiveStreakThresholdUSD, 5)

        let memberData = #"{"handle":"kevin","streak_threshold_usd":7,"days":[]}"#.data(using: .utf8)!
        let member = try JSONDecoder().decode(MemberDetail.self, from: memberData)
        XCTAssertEqual(member.effectiveStreakThresholdUSD, 7)
    }

    private func model(_ name: String, cost: Double?, tokens: Int) -> BurnReport.ModelUsage {
        .init(source: "codex", model: name, inputTokens: tokens, outputTokens: 0, totalTokens: tokens, costUSD: cost)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }
}
