import XCTest
@testable import BrrrnCore

final class ModelPresentationTests: XCTestCase {
    func testClaudeVariantsAreAlwaysExplicit() {
        XCTAssertEqual(ModelPresentation(source: "claude-code", speed: "standard").provider, .claude)
        XCTAssertEqual(ModelPresentation(source: "claude-code", speed: "standard").variantLabel, "Standard")
        XCTAssertEqual(ModelPresentation(source: "claude", speed: "fast").variantLabel, "Fast")
        XCTAssertEqual(ModelPresentation(source: "claude", speed: nil).variantLabel, "Standard")
    }

    func testCodexVariantsIdentifyReasoningLevel() {
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "default").provider, .codex)
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "default").variantLabel, "Reasoning: Default")
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "high").variantLabel, "Reasoning: High")
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "xhigh").variantLabel, "Reasoning: X-High")
        XCTAssertEqual(ModelPresentation(source: "openai", speed: "minimal").variantLabel, "Reasoning: Minimal")
    }

    func testUnknownValuesRemainReadable() {
        let presentation = ModelPresentation(source: "other", speed: "very_high")
        XCTAssertEqual(presentation.provider, .unknown)
        XCTAssertEqual(presentation.provider.displayName, "Other")
        XCTAssertEqual(presentation.variantLabel, "Very High")
    }

    func testModelPresentationKeepsSpeedRowsDistinct() {
        let standard = BurnReport.ModelUsage(source: "claude-code", model: "claude-opus", speed: "standard")
        let fast = BurnReport.ModelUsage(source: "claude-code", model: "claude-opus", speed: "fast")

        XCTAssertNotEqual(standard.id, fast.id)
        XCTAssertEqual(standard.presentation.variantLabel, "Standard")
        XCTAssertEqual(fast.presentation.variantLabel, "Fast")
    }
}
