import XCTest
@testable import BrrrnCore

final class DailyActivityTests: XCTestCase {
    func testGridUsesCompleteMondayThroughSundayUTCWeeks() {
        let grid = UTCActivityGrid(entries: [], weeks: 16, endingAt: utcDate(2026, 7, 14))

        XCTAssertEqual(grid.cells.count, 112)
        XCTAssertEqual(grid.cells.first?.dateKey, "2026-03-30")
        XCTAssertEqual(grid.cells.first?.weekdayIndex, 0)
        XCTAssertEqual(grid.cells.last?.dateKey, "2026-07-19")
        XCTAssertTrue(grid.cells.last?.isFuture == true)
        XCTAssertEqual(grid.cells.first(where: { $0.dateKey == "2026-07-14" })?.weekdayIndex, 1)
    }

    func testGridKeepsUTCDayAtMidnightAcrossLocalTimeZones() {
        let instant = Date(timeIntervalSince1970: 1_768_262_400) // 2026-01-13 00:00:00 UTC
        let grid = UTCActivityGrid(entries: [], weeks: 1, endingAt: instant)

        XCTAssertEqual(grid.endDateKey, "2026-01-13")
        XCTAssertEqual(grid.cells.first(where: { $0.isToday })?.dateKey, "2026-01-13")
    }

    func testCostLevelCasesStayInAscendingSpendOrder() {
        XCTAssertEqual(
            Array(DailyCostLevel.allCases.dropFirst()),
            [.belowThreshold, .active, .high, .veryHigh, .extreme]
        )
    }

    func testCostLevelsUseStreakRelativeBoundaries() {
        let entries = [
            entry("2026-07-13", tokens: 1_000_000, cost: 0),
            entry("2026-07-14", cost: 4.99),
            entry("2026-07-15", cost: 5),
            entry("2026-07-16", cost: 25),
            entry("2026-07-17", cost: 100),
            entry("2026-07-18", cost: 500),
        ]
        let grid = UTCActivityGrid(entries: entries, weeks: 1, endingAt: utcDate(2026, 7, 19), thresholdUSD: 5)

        XCTAssertEqual(level("2026-07-13", in: grid), .none)
        XCTAssertEqual(level("2026-07-14", in: grid), .belowThreshold)
        XCTAssertEqual(level("2026-07-15", in: grid), .active)
        XCTAssertEqual(level("2026-07-16", in: grid), .high)
        XCTAssertEqual(level("2026-07-17", in: grid), .veryHigh)
        XCTAssertEqual(level("2026-07-18", in: grid), .extreme)
    }

    func testMissingAndTokenBearingUnpricedDaysStayDistinct() {
        let grid = UTCActivityGrid(
            entries: [entry("2026-07-14", tokens: 100, cost: 0)],
            weeks: 1,
            endingAt: utcDate(2026, 7, 19)
        )

        XCTAssertEqual(cell("2026-07-13", in: grid).status, .noUsage)
        XCTAssertFalse(cell("2026-07-13", in: grid).hasRecord)
        XCTAssertEqual(cell("2026-07-14", in: grid).status, .unpriced)
        XCTAssertTrue(cell("2026-07-14", in: grid).hasRecord)
    }

    func testIncompleteTodayDoesNotBreakCurrentStreak() {
        let grid = UTCActivityGrid(
            entries: [
                entry("2026-07-12", cost: 6),
                entry("2026-07-13", cost: 7),
                entry("2026-07-14", cost: 1),
            ],
            weeks: 2,
            endingAt: utcDate(2026, 7, 14),
            thresholdUSD: 5
        )

        XCTAssertEqual(grid.currentStreakDays, 2)
        XCTAssertEqual(cell("2026-07-12", in: grid).status, .currentStreak)
        XCTAssertEqual(cell("2026-07-13", in: grid).status, .currentStreak)
        XCTAssertEqual(cell("2026-07-14", in: grid).status, .belowThreshold)
    }

    func testCompletedBelowThresholdDayBreaksCurrentStreak() {
        let grid = UTCActivityGrid(
            entries: [
                entry("2026-07-12", cost: 6),
                entry("2026-07-13", cost: 4),
                entry("2026-07-14", cost: 1),
            ],
            weeks: 2,
            endingAt: utcDate(2026, 7, 14),
            thresholdUSD: 5
        )

        XCTAssertEqual(grid.currentStreakDays, 0)
        XCTAssertEqual(cell("2026-07-12", in: grid).status, .thresholdMet)
    }

    func testCostRatherThanTokenVolumeControlsIntensity() {
        let grid = UTCActivityGrid(
            entries: [
                entry("2026-07-13", tokens: 10_000_000, cost: 1),
                entry("2026-07-14", tokens: 10, cost: 100),
            ],
            weeks: 1,
            endingAt: utcDate(2026, 7, 14)
        )

        XCTAssertEqual(level("2026-07-13", in: grid), .belowThreshold)
        XCTAssertEqual(level("2026-07-14", in: grid), .veryHigh)
    }

    func testInvalidThresholdFallsBackToDefaultPolicy() {
        for threshold in [0, -1, .infinity, .nan] {
            let grid = UTCActivityGrid(
                entries: [entry("2026-07-14", cost: 6)],
                weeks: 1,
                endingAt: utcDate(2026, 7, 14),
                thresholdUSD: threshold
            )

            XCTAssertEqual(grid.thresholdUSD, StreakPolicy.defaultThresholdUSD)
            XCTAssertEqual(grid.currentStreakDays, 1)
            XCTAssertEqual(cell("2026-07-14", in: grid).status, .currentStreak)
        }
    }

    func testMicrodollarNormalizationCountsAccumulatedThresholdAsMet() {
        let entries = (0..<50).map { _ in
            entry("2026-07-14", cost: 0.1)
        }
        let grid = UTCActivityGrid(
            entries: entries,
            weeks: 1,
            endingAt: utcDate(2026, 7, 14),
            thresholdUSD: 5
        )

        XCTAssertEqual(grid.currentStreakDays, 1)
        XCTAssertEqual(cell("2026-07-14", in: grid).level, .active)
        XCTAssertEqual(cell("2026-07-14", in: grid).status, .currentStreak)
    }

    private func cell(_ date: String, in grid: UTCActivityGrid) -> DailyActivityCell {
        grid.cells.first(where: { $0.dateKey == date })!
    }

    private func level(_ date: String, in grid: UTCActivityGrid) -> DailyCostLevel {
        cell(date, in: grid).level
    }

    private func entry(_ date: String, tokens: Int = 0, cost: Double) -> BurnReport.DailyEntry {
        .init(date: date, tokens: tokens, costUSD: cost)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = BurnReport.DailyEntry.utcCalendar
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }
}
