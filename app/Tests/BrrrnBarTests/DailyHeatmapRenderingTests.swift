import SwiftUI
import XCTest
import BrrrnCore
@testable import BrrrnBar

final class DailyHeatmapRenderingTests: XCTestCase {
    @MainActor
    func testHeatmapRendersInsideMenuContentWidth() throws {
        let grid = fixtureGrid(weeks: 16)
        let renderer = ImageRenderer(content:
            DailyHeatmap(title: "BURN CALENDAR", grid: grid)
                .padding(18)
                .frame(width: 390)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 780)
        XCTAssertGreaterThan(image.height, 200)
    }

    @MainActor
    func testHeatmapRendersInDarkAppearance() throws {
        let renderer = ImageRenderer(content:
            DailyHeatmap(title: "BURN CALENDAR", grid: fixtureGrid(weeks: 16))
                .padding(18)
                .frame(width: 390)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 780)
        XCTAssertGreaterThan(image.height, 200)
    }

    @MainActor
    func testSixteenWeekHeatmapIntrinsicWidthFitsMenuContent() throws {
        let renderer = ImageRenderer(content:
            DailyHeatmap(title: "16-WEEK BURN CALENDAR", grid: fixtureGrid(weeks: 16))
                .fixedSize(horizontal: true, vertical: false)
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertLessThanOrEqual(image.width, 708)
    }

    func testArrowNavigationStopsAtWeekdayEdges() {
        let grid = UTCActivityGrid(entries: [], weeks: 2, endingAt: utcDate(2026, 7, 19))

        XCTAssertNil(HeatmapNavigation.targetIndex(from: 7, direction: .up, cells: grid.cells))
        XCTAssertNil(HeatmapNavigation.targetIndex(from: 13, direction: .down, cells: grid.cells))
        XCTAssertEqual(HeatmapNavigation.targetIndex(from: 7, direction: .left, cells: grid.cells), 0)
        XCTAssertNil(HeatmapNavigation.targetIndex(from: 0, direction: .left, cells: grid.cells))
    }

    func testAccessibilityDayNavigationCanCrossWeekBoundary() {
        let grid = UTCActivityGrid(entries: [], weeks: 2, endingAt: utcDate(2026, 7, 19))

        XCTAssertEqual(HeatmapNavigation.targetIndex(from: 6, direction: .nextDay, cells: grid.cells), 7)
        XCTAssertEqual(HeatmapNavigation.targetIndex(from: 7, direction: .previousDay, cells: grid.cells), 6)
    }

    private func fixtureGrid(weeks: Int) -> UTCActivityGrid {
        let entries = [
            BurnReport.DailyEntry(date: "2026-07-12", tokens: 500, costUSD: 4),
            BurnReport.DailyEntry(date: "2026-07-13", tokens: 900, costUSD: 8),
            BurnReport.DailyEntry(date: "2026-07-14", tokens: 1_200, costUSD: 12),
        ]
        return UTCActivityGrid(
            entries: entries,
            weeks: weeks,
            endingAt: utcDate(2026, 7, 14)
        )
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
