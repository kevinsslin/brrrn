import SwiftUI

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

    static func chart(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
            : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
    }
}
