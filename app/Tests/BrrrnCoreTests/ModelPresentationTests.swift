import XCTest
@testable import BrrrnCore

final class ModelPresentationTests: XCTestCase {
    func testDefaultModesShowNoSuffix() {
        XCTAssertEqual(ModelPresentation(source: "claude-code", speed: "standard").provider, .claude)
        XCTAssertNil(ModelPresentation(source: "claude-code", speed: "standard").variantSuffix)
        XCTAssertNil(ModelPresentation(source: "claude", speed: nil).variantSuffix)
        XCTAssertNil(ModelPresentation(source: "codex", speed: "default").variantSuffix)
        XCTAssertEqual(
            ModelPresentation(source: "claude", speed: "standard").title(for: "claude-fable-5"),
            "claude-fable-5"
        )
    }

    func testMeaningfulVariantsBecomeParentheticalSuffixes() {
        XCTAssertEqual(ModelPresentation(source: "claude", speed: "fast").variantSuffix, "fast")
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "high").variantSuffix, "high")
        XCTAssertEqual(ModelPresentation(source: "codex", speed: "xhigh").variantSuffix, "x-high")
        XCTAssertEqual(ModelPresentation(source: "openai", speed: "minimal").variantSuffix, "minimal")
        XCTAssertEqual(
            ModelPresentation(source: "codex", speed: "xhigh").title(for: "gpt-5.6-sol"),
            "gpt-5.6-sol (x-high)"
        )
    }

    func testUnknownValuesRemainReadable() {
        let presentation = ModelPresentation(source: "other", speed: "very_high")
        XCTAssertEqual(presentation.provider, .unknown)
        XCTAssertEqual(presentation.provider.displayName, "Other")
        XCTAssertEqual(presentation.variantSuffix, "very-high")
    }

    func testModelPresentationKeepsSpeedRowsDistinct() {
        let standard = BurnReport.ModelUsage(source: "claude-code", model: "claude-opus", speed: "standard")
        let fast = BurnReport.ModelUsage(source: "claude-code", model: "claude-opus", speed: "fast")

        XCTAssertNotEqual(standard.id, fast.id)
        XCTAssertEqual(standard.displayTitle, "claude-opus")
        XCTAssertEqual(fast.displayTitle, "claude-opus (fast)")
    }

    func testDefaultAvatarsAreStableAndInPool() {
        XCTAssertEqual(MemberAvatar.emoji(for: "kevin"), MemberAvatar.emoji(for: "kevin"))
        XCTAssertTrue(MemberAvatar.pool.contains(MemberAvatar.emoji(for: "kevin")))
        // Common short handles should not all collapse onto one face.
        let faces = Set(["kevin", "alice", "bob", "carol", "dave"].map(MemberAvatar.emoji(for:)))
        XCTAssertGreaterThan(faces.count, 2)
    }
}
