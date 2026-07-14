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
        let light = [0xC0652D, 0xA94C0A, 0x903800, 0x742B00, 0x571F00]
        let dark = [0xFFE0C7, 0xFFB778, 0xF39648, 0xDC7726, 0xBC5B00]
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
