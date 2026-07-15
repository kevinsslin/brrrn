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
        let rhythm = BurnAnalytics.rhythm(
            entries: entries,
            lookbackDays: 14,
            endingAt: utcDate(2026, 7, 14),
            timeZone: TimeZone(identifier: "UTC")!
        )

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
        let rhythm = BurnAnalytics.rhythm(
            entries: entries,
            lookbackDays: 14,
            endingAt: utcDate(2026, 7, 14),
            timeZone: TimeZone(identifier: "UTC")!
        )

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

    func testRhythmRebucketsUTCHoursIntoViewerTimezoneAcrossDayBoundary() {
        var lateUTC = [Double](repeating: 0, count: 24)
        lateUTC[23] = 10 // 2026-07-13 23:00 UTC = 2026-07-14 01:00 in UTC+2
        let entries = [BurnReport.DailyEntry(date: "2026-07-13", costUSD: 10, hours: lateUTC)]
        let plusTwo = TimeZone(secondsFromGMT: 7200)!

        let rhythm = BurnAnalytics.rhythm(
            entries: entries,
            endingAt: utcDate(2026, 7, 14).addingTimeInterval(6 * 3600),
            timeZone: plusTwo
        )

        XCTAssertEqual(rhythm.todayByHour[1], 10, accuracy: 1e-9)
        XCTAssertEqual(rhythm.todayByHour[23], 0, accuracy: 1e-9)
        XCTAssertEqual(rhythm.activeDays, 0)

        // The same data viewed in UTC belongs to yesterday's typical profile.
        let utcView = BurnAnalytics.rhythm(
            entries: entries,
            endingAt: utcDate(2026, 7, 14).addingTimeInterval(6 * 3600),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(utcView.todayByHour[23], 0, accuracy: 1e-9)
        XCTAssertEqual(utcView.typicalByHour[23], 10, accuracy: 1e-9)
        XCTAssertEqual(utcView.activeDays, 1)
    }

    func testRecordsFindBestHourBestDayAndLongestStreak() {
        var spike = [Double](repeating: 0, count: 24)
        spike[13] = 120
        var mild = [Double](repeating: 0, count: 24)
        mild[9] = 6

        let entries = [
            BurnReport.DailyEntry(date: "2026-07-01", costUSD: 6, hours: mild),
            BurnReport.DailyEntry(date: "2026-07-02", costUSD: 7),
            BurnReport.DailyEntry(date: "2026-07-03", costUSD: 8),
            // gap on 07-04
            BurnReport.DailyEntry(date: "2026-07-05", costUSD: 200, hours: spike),
            BurnReport.DailyEntry(date: "2026-07-06", costUSD: 2), // below threshold
        ]
        let records = BurnAnalytics.records(
            entries: entries,
            thresholdUSD: 5,
            endingAt: utcDate(2026, 7, 14)
        )

        XCTAssertEqual(records.bestDay?.costUSD, 200)
        XCTAssertEqual(records.bestDay?.isCurrent, false)
        XCTAssertEqual(records.bestHour?.costUSD, 120)
        XCTAssertEqual(BurnAnalytics.dateKey(records.bestHour!.date), "2026-07-05")
        XCTAssertEqual(records.longestStreakDays, 3)
        XCTAssertEqual(records.longestStreakEnd.map(BurnAnalytics.dateKey), "2026-07-03")
        XCTAssertFalse(records.longestStreakIsCurrent)
    }

    func testRecordsMarkTodayAndOngoingStreakAsCurrent() {
        var burst = [Double](repeating: 0, count: 24)
        burst[2] = 55
        let entries = [
            BurnReport.DailyEntry(date: "2026-07-12", costUSD: 9),
            BurnReport.DailyEntry(date: "2026-07-13", costUSD: 10),
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 55, hours: burst),
        ]
        let records = BurnAnalytics.records(
            entries: entries,
            thresholdUSD: 5,
            endingAt: utcDate(2026, 7, 14)
        )

        XCTAssertEqual(records.bestDay?.isCurrent, true)
        XCTAssertEqual(records.bestHour?.isCurrent, true)
        XCTAssertEqual(records.longestStreakDays, 3)
        XCTAssertTrue(records.longestStreakIsCurrent)
    }

    func testRecordsKeepIncompleteTodayFromEndingTheOngoingStreak() {
        let entries = [
            BurnReport.DailyEntry(date: "2026-07-12", costUSD: 9),
            BurnReport.DailyEntry(date: "2026-07-13", costUSD: 10),
            BurnReport.DailyEntry(date: "2026-07-14", costUSD: 1), // today, not over yet
        ]
        let records = BurnAnalytics.records(
            entries: entries,
            thresholdUSD: 5,
            endingAt: utcDate(2026, 7, 14)
        )

        XCTAssertEqual(records.longestStreakDays, 2)
        XCTAssertTrue(records.longestStreakIsCurrent)
    }

    func testPitInviteParsingRoundTrips() {
        XCTAssertEqual(PitInvite.parse("ember-fox-7k2m").code, "ember-fox-7k2m")
        XCTAssertNil(PitInvite.parse("ember-fox-7k2m").hubURL)

        let full = PitInvite.parse(" Ember-Fox-7K2M@https://brrrn.example.workers.dev/ ")
        XCTAssertEqual(full.code, "ember-fox-7k2m")
        XCTAssertEqual(full.hubURL, "https://brrrn.example.workers.dev/")

        let bare = PitInvite.parse("ember-fox-7k2m@brrrn.example.workers.dev")
        XCTAssertEqual(bare.hubURL, "https://brrrn.example.workers.dev")

        XCTAssertEqual(
            PitInvite.compose(code: "ember-fox-7k2m", hubURL: "https://h.example"),
            "ember-fox-7k2m@https://h.example"
        )
        XCTAssertEqual(PitInvite.compose(code: "ember-fox-7k2m", hubURL: nil), "ember-fox-7k2m")
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return BurnReport.DailyEntry.utcCalendar.date(from: components)!
    }
}
