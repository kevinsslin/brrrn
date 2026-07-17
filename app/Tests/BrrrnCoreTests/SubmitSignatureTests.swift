import XCTest
@testable import BrrrnCore

final class SubmitSignatureTests: XCTestCase {
    // Wednesday 2026-01-07 12:00 UTC; yesterday is 2026-01-06.
    private let now = utc(2026, 1, 7)

    private func daily(_ entries: [(String, Int, Double)]) -> [BurnReport.DailyEntry] {
        entries.map { BurnReport.DailyEntry(date: $0.0, tokens: $0.1, costUSD: $0.2) }
    }

    func testIdenticalDataProducesIdenticalSignature() {
        let data = daily([("2026-01-06", 350, 6), ("2026-01-07", 1800, 10)])
        XCTAssertEqual(
            SubmitSignature.of(daily: data, now: now),
            SubmitSignature.of(daily: data, now: now)
        )
    }

    func testChangingTodayChangesSignature() {
        let before = daily([("2026-01-07", 1800, 10)])
        let after = daily([("2026-01-07", 1850, 10.25)])
        XCTAssertNotEqual(
            SubmitSignature.of(daily: before, now: now),
            SubmitSignature.of(daily: after, now: now)
        )
    }

    func testChangingADayOutsideTheWindowIsIgnored() {
        // Only today and yesterday are pushed, so an edit to an older day must
        // not force a submit.
        let before = daily([("2026-01-04", 900, 7), ("2026-01-06", 350, 6), ("2026-01-07", 1800, 10)])
        let after = daily([("2026-01-04", 999, 42), ("2026-01-06", 350, 6), ("2026-01-07", 1800, 10)])
        XCTAssertEqual(
            SubmitSignature.of(daily: before, now: now),
            SubmitSignature.of(daily: after, now: now)
        )
    }

    func testWindowFollowsNow() {
        // The same data seen a day later covers a different two-day window.
        let data = daily([("2026-01-06", 350, 6), ("2026-01-07", 1800, 10)])
        XCTAssertNotEqual(
            SubmitSignature.of(daily: data, now: now),
            SubmitSignature.of(daily: data, now: utc(2026, 1, 8))
        )
    }

    func testMissingDayIsStableUntilItAppears() {
        let quiet = daily([("2026-01-06", 350, 6)])
        let burned = daily([("2026-01-06", 350, 6), ("2026-01-07", 10, 0.5)])
        XCTAssertNotEqual(
            SubmitSignature.of(daily: quiet, now: now),
            SubmitSignature.of(daily: burned, now: now)
        )
    }
}

func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.date(from: components)!
}
