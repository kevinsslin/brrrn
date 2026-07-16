import XCTest
import BrrrnCore
@testable import BrrrnBar

final class AppModelTests: XCTestCase {
    @MainActor
    func testModelsUsesBundledPeriodsWithoutLegacyReports() {
        let model = AppModel()
        let empty = BurnReport.Window()
        model.report = BurnReport(
            windows: .init(today: empty, week: empty, month: empty, all: empty),
            modelsByPeriod: .init(
                today: [usage("today")],
                week: [usage("week")],
                month: [usage("month")]
            )
        )

        XCTAssertEqual(model.models(for: .today).map(\.model), ["today"])
        XCTAssertEqual(model.models(for: .week).map(\.model), ["week"])
        XCTAssertEqual(model.models(for: .month).map(\.model), ["month"])
    }

    private func usage(_ model: String) -> BurnReport.ModelUsage {
        BurnReport.ModelUsage(source: "codex", model: model, costUSD: 1)
    }
}
