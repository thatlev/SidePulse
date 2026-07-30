// SidePulseMacApp.swift — menu-bar-only app. No window, no Dock icon
// (LSUIElement in Info.plist); the strip in the menu bar is the whole UI.

import SwiftUI

@main
struct SidePulseMacApp: App {
    @StateObject private var model = ServerModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .task { startOnce() }
        } label: {
            // Showing the live strip in the menu bar is the point of the app:
            // the status light is visible without opening anything.
            MenuBarStrip(program: model.program)
                .task { startOnce() }
        }
        .menuBarExtraStyle(.window)
    }

    /// `.task` fires on both the label and the popover; the server must only be
    /// brought up once.
    private func startOnce() {
        guard !model.isRunning else { return }
        model.start()
    }
}
