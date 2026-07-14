import SwiftUI
import BrrrnCore

enum BrrrnPalette {
    static func claude(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xE8 / 255, green: 0x95 / 255, blue: 0x75 / 255)
            : Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    }

    static func codex(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x4C / 255, green: 0xCF / 255, blue: 0xA5 / 255)
            : Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
    }

    static func heatmap(_ level: DailyCostLevel, _ scheme: ColorScheme) -> Color {
        let light = [0x86B6EF, 0x5598E7, 0x2A78D6, 0x1C5CAB, 0x104281]
        let dark = [0x184F95, 0x256ABF, 0x3987E5, 0x6DA7EC, 0xB7D3F6]
        guard level != .none else { return heatmapEmpty(scheme) }
        let values = scheme == .dark ? dark : light
        return color(values[level.rawValue - 1])
    }

    static func heatmapEmpty(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? color(0x2C2C2A)
            : color(0xE1E0D9)
    }

    private static func color(_ hex: Int) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
