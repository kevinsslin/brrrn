import SwiftUI

enum BrrrnPalette {
    static func claude(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
            : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
    }

    static func codex(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
            : Color(red: 0x1B / 255, green: 0xAF / 255, blue: 0x7A / 255)
    }

    static func chart(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
            : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
    }
}
