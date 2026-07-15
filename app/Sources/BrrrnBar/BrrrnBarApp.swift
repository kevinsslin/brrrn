import SwiftUI
import AppKit

@main
struct BrrrnBarApp: App {
    @StateObject private var model = AppModel()

    init() {
        ScreenshotGenerator.runIfRequested()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            BrrrnMenuView(model: model)
                .frame(width: 390, height: 620)
                .onAppear { model.start() }
        } label: {
            Label(model.menuBarTitle ?? "", systemImage: "flame.fill")
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
