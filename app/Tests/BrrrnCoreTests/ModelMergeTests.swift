import XCTest
@testable import BrrrnCore

final class ModelMergeTests: XCTestCase {
    func testCodexPriorityFoldsIntoItsEffortRow() {
        let rows = [
            BurnReport.ModelUsage(source: "codex", model: "gpt-5.6-sol", speed: "xhigh",
                                  inputTokens: 100, outputTokens: 50, totalTokens: 150, costUSD: 10),
            BurnReport.ModelUsage(source: "codex", model: "gpt-5.6-sol", speed: "xhigh priority",
                                  inputTokens: 40, outputTokens: 20, totalTokens: 60, costUSD: 4),
            BurnReport.ModelUsage(source: "codex", model: "gpt-5.6-sol", speed: "medium",
                                  inputTokens: 10, outputTokens: 5, totalTokens: 15, costUSD: 1),
        ]
        let merged = ModelMerge.foldFastMode(rows)

        XCTAssertEqual(merged.count, 2)
        let xhigh = merged[0]
        XCTAssertEqual(xhigh.speed, "xhigh")
        XCTAssertEqual(xhigh.totalTokens, 210)
        XCTAssertEqual(xhigh.costUSD, 14)
        XCTAssertEqual(xhigh.fastCostUSD, 4)
        XCTAssertEqual(xhigh.fastTotalTokens, 60)
        XCTAssertEqual(xhigh.displayTitle, "gpt-5.6-sol (x-high)")
        XCTAssertEqual(merged[1].fastCostUSD, 0)
    }

    func testClaudeFastFoldsIntoTheStandardRow() {
        let rows = [
            BurnReport.ModelUsage(source: "claude", model: "claude-opus-4-8", speed: "standard",
                                  inputTokens: 100, outputTokens: 10, totalTokens: 110, costUSD: 8),
            BurnReport.ModelUsage(source: "claude", model: "claude-opus-4-8", speed: "fast",
                                  inputTokens: 30, outputTokens: 5, totalTokens: 35, costUSD: 3),
        ]
        let merged = ModelMerge.foldFastMode(rows)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].displayTitle, "claude-opus-4-8")
        XCTAssertEqual(merged[0].costUSD, 11)
        XCTAssertEqual(merged[0].fastCostUSD, 3)
        XCTAssertEqual(merged[0].fastTotalTokens, 35)
    }

    func testFastOnlyRowKeepsItsIdentityWithFullFastShare() {
        let rows = [
            BurnReport.ModelUsage(source: "claude", model: "claude-fable-5", speed: "fast",
                                  inputTokens: 30, outputTokens: 5, totalTokens: 35, costUSD: 3),
        ]
        let merged = ModelMerge.foldFastMode(rows)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].displayTitle, "claude-fable-5")
        XCTAssertEqual(merged[0].fastCostUSD, 3)
    }

    func testUnpricedRowsStayUnpriced() {
        let rows = [
            BurnReport.ModelUsage(source: "codex", model: "mystery", speed: "high",
                                  inputTokens: 10, outputTokens: 5, totalTokens: 15, costUSD: nil),
            BurnReport.ModelUsage(source: "codex", model: "mystery", speed: "high priority",
                                  inputTokens: 10, outputTokens: 5, totalTokens: 15, costUSD: nil),
        ]
        let merged = ModelMerge.foldFastMode(rows)

        XCTAssertEqual(merged.count, 1)
        XCTAssertNil(merged[0].costUSD)
        XCTAssertEqual(merged[0].fastCostUSD, 0)
        XCTAssertEqual(merged[0].fastTotalTokens, 15)
    }

    func testFoldKeyDoesNotMergeDistinctModelAndVariantComponents() {
        let rows = [
            BurnReport.ModelUsage(source: "codex", model: "custom|xhigh", speed: "medium",
                                  inputTokens: 10, totalTokens: 10, costUSD: 1),
            BurnReport.ModelUsage(source: "codex", model: "custom", speed: "xhigh|medium",
                                  outputTokens: 20, totalTokens: 20, costUSD: 2),
        ]

        let merged = ModelMerge.foldFastMode(rows)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.costUSD), [1, 2])
    }
}
