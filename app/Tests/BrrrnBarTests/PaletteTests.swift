import AppKit
import SwiftUI
import XCTest
import BrrrnCore
@testable import BrrrnBar

final class PaletteTests: XCTestCase {
    @MainActor
    func testHeatmapUsesApprovedEmberRamp() throws {
        XCTAssertEqual(
            try heatmapHexes(.light),
            [0xC0652D, 0xA94C0A, 0x903800, 0x742B00, 0x571F00]
        )
        XCTAssertEqual(
            try heatmapHexes(.dark),
            [0xFFE0C7, 0xFFB778, 0xF39648, 0xDC7726, 0xBC5B00]
        )
    }

    @MainActor
    func testHeatmapGetsDarkerAsCostLevelIncreasesInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let luminances = try DailyCostLevel.allCases.dropFirst().map {
                try relativeLuminance(BrrrnPalette.heatmap($0, scheme))
            }

            for index in 0..<(luminances.count - 1) {
                XCTAssertGreaterThan(
                    luminances[index],
                    luminances[index + 1],
                    "Expected level \(index + 1) to be lighter than level \(index + 2) in \(scheme) mode"
                )
            }
        }
    }

    @MainActor
    func testHeatmapEndpointsRemainDistinctFromEmptyCells() throws {
        XCTAssertGreaterThanOrEqual(
            try contrastRatio(
                BrrrnPalette.heatmap(.belowThreshold, .light),
                BrrrnPalette.heatmapEmpty(.light)
            ),
            3
        )
        XCTAssertGreaterThanOrEqual(
            try contrastRatio(
                BrrrnPalette.heatmap(.extreme, .dark),
                BrrrnPalette.heatmapEmpty(.dark)
            ),
            3
        )
        XCTAssertEqual(try hex(BrrrnPalette.heatmap(.none, .light)), 0xE1E0D9)
        XCTAssertEqual(try hex(BrrrnPalette.heatmap(.none, .dark)), 0x2C2C2A)
    }

    @MainActor
    private func heatmapHexes(_ scheme: ColorScheme) throws -> [Int] {
        try DailyCostLevel.allCases.dropFirst().map {
            try hex(BrrrnPalette.heatmap($0, scheme))
        }
    }

    @MainActor
    private func contrastRatio(_ first: Color, _ second: Color) throws -> Double {
        let firstLuminance = try relativeLuminance(first)
        let secondLuminance = try relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    @MainActor
    private func relativeLuminance(_ color: Color) throws -> Double {
        let components = try sRGBComponents(color)
        let linear = components.map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    @MainActor
    private func hex(_ color: Color) throws -> Int {
        let components = try sRGBComponents(color)
        return components.reduce(0) { value, component in
            (value << 8) | Int((component * 255).rounded())
        }
    }

    @MainActor
    private func sRGBComponents(_ color: Color) throws -> [Double] {
        let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
    }
}
