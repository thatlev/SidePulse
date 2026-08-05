// main.swift — menu-bar-only app. No Dock icon and no window, ever: the status
// item strip is the whole UI.
//
// Plain AppKit rather than a SwiftUI `App` scene, because the only scene this
// app has is a status item, and SwiftUI's `MenuBarExtra` does not render an
// animated label reliably. See MenuBarController.swift.

import AppKit

let app = NSApplication.shared
// `.accessory` = no Dock icon, no app menu, no window on launch. `LSUIElement`
// in Info.plist does the same for a bundled launch; setting it here keeps
// `swift run` behaving identically during development.
app.setActivationPolicy(.accessory)

// main.swift runs before the main actor is formally established, but this *is*
// the main thread, which is what the delegate's isolation actually requires.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
