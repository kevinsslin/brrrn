import XCTest
@testable import BrrrnCore

final class BurnAnalyticsTests: XCTestCase {
    func testTrendGapFillsQuietDaysWithZero() {
        let entries = [
            BurnReport.DailyEntry(date: "2026-07-12", costUSD: 40),
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 10),
        ]
        let points = BurnAnalytics.trend(entries: entries, days: 5, endingAt: utcDate(2026, 7, 14))

        XCTAssertEqual(points.map(\.dateKey), [
            "2026-07-10", "2026-07-11", "2026-07-12", "2026-07-13", "2026-07-14",
        ])
        XCTAssertEqual(points.map(\.costUSD), [0, 0, 40, 0, 10])
    }

    func testTrendMergesDuplicateDateEntries() {
        let entries = [
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 10),
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 5),
        ]
        let points = BurnAnalytics.trend(entries: entries, days: 1, endingAt: utcDate(2026, 7, 14))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].costUSD, 15)
    }

    func testRhythmSeparatesTodayFromTypicalAndAveragesActiveDaysOnly() {
        var morning = [Double](repeating: 0, count: 24)
        morning[9] = 30
        var evening = [Double](repeating: 0, count: 24)
        evening[9] = 10
        evening[21] = 50
        let idle = [Double](repeating: 0, count: 24)
        var today = [Double](repeating: 0, count: 24)
        today[13] = 7

        let entries = [
            BurnReport.DailyEntry(date: "2026-07-12", costUSD: 30, hours: morning),
            BurnReport.DailyEntry(date: "2026-07-13", costUSD: 60, hours: evening),
            BurnReport.DailyEntry(date: "2026-07-11", costUSD: 0, hours: idle), // ignored: no burn
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 7, hours: today),
        ]
        let rhythm = BurnAnalytics.rhythm(entries: entries, lookbackDays: 14, endingAt: utcDate(2026, 7, 14))

        XCTAssertTrue(rhythm.hasData)
        XCTAssertEqual(rhythm.activeDays, 2)
        XCTAssertEqual(rhythm.typicalByHour[9], 20, accuracy: 1e-9)
        XCTAssertEqual(rhythm.typicalByHour[21], 25, accuracy: 1e-9)
        XCTAssertEqual(rhythm.todayByHour[13], 7, accuracy: 1e-9)
        XCTAssertEqual(rhythm.todayByHour[9], 0, accuracy: 1e-9)
        XCTAssertEqual(rhythm.peakTypicalHour, 21)
    }

    func testRhythmIgnoresDaysOutsideLookbackAndMalformedHourArrays() {
        var stale = [Double](repeating: 0, count: 24)
        stale[3] = 99
        let entries = [
            BurnReport.DailyEntry(date: "2026-06-01", costUSD: 99, hours: stale), // too old
            BurnReport.DailyEntry(date: "2026-07-13", costUSD: 5, hours: [1, 2, 3]), // malformed
            BurnReport.DailyEntry(date: "2026-07-12", costUSD: 5), // legacy engine: no hours
        ]
        let rhythm = BurnAnalytics.rhythm(entries: entries, lookbackDays: 14, endingAt: utcDate(2026, 7, 14))

        XCTAssertFalse(rhythm.hasData)
        XCTAssertEqual(rhythm.activeDays, 0)
        XCTAssertNil(rhythm.peakTypicalHour)
    }

    func testDailyEntryDecodesOptionalHourArrays() throws {
        let json = """
        [
            {"date": "2026-07-14", "tokens": 100, "cost_usd": 12.5,
             "hours": [0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
             "hour_tokens": [10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 90, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]},
            {"date": "2026-07-13", "tokens": 5, "cost_usd": 1.0}
        ]
        """
        let entries = try JSONDecoder().decode([BurnReport.DailyEntry].self, from: Data(json.utf8))

        XCTAssertEqual(entries[0].hours?.count, 24)
        XCTAssertEqual(entries[0].hours?[12], 12)
        XCTAssertEqual(entries[0].hourTokens?[12], 90)
        XCTAssertNil(entries[1].hours)
        XCTAssertNil(entries[1].hourTokens)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return BurnReport.DailyEntry.utcCalendar.date(from: components)!
    }
}
