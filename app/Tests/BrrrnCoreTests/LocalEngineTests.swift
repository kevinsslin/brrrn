import XCTest
@testable import BrrrnCore

final class LocalEngineTests: XCTestCase {
    func testRefreshReportsUsesOneInvocationWhenModelsByPeriodAreBundled() async throws {
        let recorder = ReportCallRecorder()
        let report = makeReport(
            modelsByPeriod: .init(
                today: [model("today")],
                week: [model("week")],
                month: [model("month")]
            )
        )

        let reports = try await LocalEngine.refreshReports { arguments in
            await recorder.record(arguments)
            return report
        }

        XCTAssertEqual(reports.all, report)
        XCTAssertNil(reports.today)
        XCTAssertNil(reports.week)
        XCTAssertNil(reports.month)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [["--json"]])
    }

    func testRefreshReportsFallsBackToLegacyPeriodInvocations() async throws {
        let recorder = ReportCallRecorder()
        let report = makeReport()

        let reports = try await LocalEngine.refreshReports { arguments in
            await recorder.record(arguments)
            return report
        }

        XCTAssertNotNil(reports.today)
        XCTAssertNotNil(reports.week)
        XCTAssertNotNil(reports.month)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.first, ["--json"])
        XCTAssertEqual(Set(calls.dropFirst()), Set([
            ["--period", "today", "--json"],
            ["--period", "week", "--json"],
            ["--period", "month", "--json"],
        ]))
    }

    private func makeReport(
        modelsByPeriod: BurnReport.ModelsByPeriod? = nil
    ) -> BurnReport {
        let empty = BurnReport.Window()
        return BurnReport(
            windows: .init(today: empty, week: empty, month: empty, all: empty),
            modelsByPeriod: modelsByPeriod
        )
    }

    private func model(_ name: String) -> BurnReport.ModelUsage {
        BurnReport.ModelUsage(source: "codex", model: name)
    }
}

private actor ReportCallRecorder {
    private(set) var calls: [[String]] = []

    func record(_ arguments: [String]) {
        calls.append(arguments)
    }
}
